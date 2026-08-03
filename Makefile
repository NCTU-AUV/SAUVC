# =============================================================================
# Orca AUV —— 全系統操作入口
# =============================================================================
# 一個指令拉起載具上的兩個堆疊，或加上模擬。
#
#   make up          啟動 control + autonomy 容器
#   make build       建置 workspace（兩個堆疊都 colcon build）
#   make launch      啟動兩個堆疊的 ROS 節點（背景）
#   make status      節點 / topic / 模式一覽
#   make stop        停掉所有 ROS 節點（容器留著）
#   make down        停掉容器
#
#   make sim_up      額外啟動模擬容器
#   make sim         模擬全鏈路：Gazebo + control(sim) + autonomy
#
# 環境設定全部來自 .env，不要在這裡寫死。
# -----------------------------------------------------------------------------

ifneq (,$(wildcard .env))
include .env
export
endif

ORCA_NAMESPACE ?= orca_auv
ARCH := $(shell uname -m)

COMPOSE_BASE ?= $(shell \
	if docker compose version >/dev/null 2>&1; then \
		printf "docker compose"; \
	elif docker-compose --version >/dev/null 2>&1; then \
		printf "docker-compose"; \
	else \
		printf ""; \
	fi)
ifeq ($(strip $(COMPOSE_BASE)),)
$(error Docker Compose not found: install Compose v2 (docker compose) or v1)
endif

# GPU 的給法在兩個平台上互斥（x86 用 gpus: all，Jetson 用 runtime: nvidia），
# 所以依架構套用不同的疊加檔。少了它 Gazebo 會直接 segfault、TensorRT 起不來。
# SOFTGL=1 代表「這台機器沒有可用的 GPU passthrough」：完全不要求 GPU，
# 模擬改用軟體算繪。它是**取代**平台疊加檔而不是疊在上面 ——
# 只要任何一個 service 還帶著 gpus/runtime，容器就會整個起不來。
# 見 docker-compose.softgl.yml
ifeq ($(SOFTGL),1)
COMPOSE := $(COMPOSE_BASE) -f docker-compose.yml -f docker-compose.softgl.yml
else ifeq ($(ARCH),aarch64)
COMPOSE := $(COMPOSE_BASE) -f docker-compose.yml -f docker-compose.jetson.yml
else
COMPOSE := $(COMPOSE_BASE) -f docker-compose.yml -f docker-compose.x86.yml
endif

CONTROL_WS  := /root/rpi_ros2_ws
AUTONOMY_WS := /workspaces/isaac_ros-dev

CONTROL_SETUP := cd $(CONTROL_WS) && \
	source /opt/ros/humble/setup.bash && \
	if [ -f /root/uros_ws/install/local_setup.bash ]; then \
		source /root/uros_ws/install/local_setup.bash; \
	fi && \
	source install/setup.bash &&

AUTONOMY_SETUP := cd $(AUTONOMY_WS) && \
	source /opt/ros/humble/setup.bash && \
	source install/setup.bash &&

# 停掉堆疊裡所有 ROS 程序。
# 用單一路徑 pattern 涵蓋所有節點，而不是逐一列出節點名 —— 逐一列出的清單
# 每次新增／改名節點都會漏，漏掉的節點會變成孤兒程序繼續跑，下次啟動就同時
# 有兩套 supervisor 互相覆蓋狀態。
#
# `[r]` 括號技巧是必要的：pkill -f 匹配整條命令列，而執行這段的
# `bash -lc '...'` 自己的命令列就含有這個 pattern，不繞開會先殺掉自己。
STOP_CONTROL := \
	pkill -INT -f '[r]os2 launch' || true; sleep 2; \
	pkill -9 -f '[r]pi_ros2_ws/install' || true; \
	pkill -9 -f '[w]eb_video_server' || true; \
	pkill -9 -f '[m]icro_ros_agent' || true; \
	pkill -9 -f '[r]os2 bag record' || true

STOP_AUTONOMY := \
	pkill -INT -f '[r]os2 launch' || true; sleep 2; \
	pkill -9 -f '[i]saac_ros-dev/install' || true

.PHONY: all up down build build_images launch launch_control launch_autonomy stop status \
        sim_up sim sim_launch xhost_grant logs_control logs_autonomy clean doctor \
        pull_autonomy submodules

all: up build launch status

# --- 容器 -------------------------------------------------------------------

submodules:
	git submodule update --init --recursive

# 冪等：容器已在跑時幾乎是 no-op，所以可以安心當成其他 target 的前置條件。
up:
	@$(COMPOSE) up -d --no-build control autonomy

down:
	$(COMPOSE) --profile sim down

# 只 build 由 compose 管理的映像（control / sim）。
# autonomy 的 Isaac 映像不在這裡 —— 見 pull_autonomy。
build_images:
	$(COMPOSE) --profile sim build control sim

# Isaac 映像請優先用 pull，不要在 Jetson 上 build。理由見
# SAUVC-JETSON/isaac_ros_common/scripts/orca_registry.sh 的說明。
pull_autonomy:
	SAUVC-JETSON/isaac_ros_common/scripts/orca_registry.sh pull

# --- workspace 建置 ---------------------------------------------------------

build:
	@echo "==> colcon build：control"
	$(COMPOSE) exec -T control /bin/bash -lc "\
		cd $(CONTROL_WS) && source /opt/ros/humble/setup.bash && \
		colcon build --symlink-install"
	@echo "==> colcon build：autonomy"
	$(COMPOSE) exec -T autonomy /bin/bash -lc "\
		cd $(AUTONOMY_WS) && source /opt/ros/humble/setup.bash && \
		colcon build --symlink-install"

# --- 啟動 -------------------------------------------------------------------

# SIM=true 時 control 堆疊跑模擬模式（跳過硬體節點）
SIM ?= false
# HEADLESS=true 時 Gazebo 只跑 server，不開 GUI
HEADLESS ?= false

launch: launch_control launch_autonomy
	@echo "節點啟動中，用 make status 查看"

launch_control: up
	@echo "==> 啟動 control 堆疊（sim=$(SIM)）"
	@$(COMPOSE) exec -T control /bin/bash -lc "$(STOP_CONTROL)" >/dev/null 2>&1 || true
	$(COMPOSE) exec -T -d control /bin/bash -lc "\
		$(CONTROL_SETUP) \
		exec ros2 launch orca_bringup bringup.launch.py sim:=$(SIM) > /tmp/control.log 2>&1"

launch_autonomy: up
	@echo "==> 啟動 autonomy 堆疊"
	@$(COMPOSE) exec -T autonomy /bin/bash -lc "$(STOP_AUTONOMY)" >/dev/null 2>&1 || true
	@# decision_node 的 tree_xml_file 是相對路徑 config/trees.xml，
	@# 必須從 orca_decision 目錄啟動，否則 BehaviorTree 載入失敗。
	$(COMPOSE) exec -T -d autonomy /bin/bash -lc "\
		$(AUTONOMY_SETUP) cd src/orca_decision && \
		exec ros2 launch orca_decision decision.launch.py > /tmp/decision.log 2>&1"

stop:
	@echo "==> 停掉所有 ROS 節點"
	-@$(COMPOSE) exec -T control  /bin/bash -lc "$(STOP_CONTROL); ros2 daemon stop || true" 2>/dev/null
	-@$(COMPOSE) exec -T autonomy /bin/bash -lc "$(STOP_AUTONOMY); ros2 daemon stop || true" 2>/dev/null
	@echo "已停止"

logs_control:
	@$(COMPOSE) exec -T control /bin/bash -lc "tail -n 200 -f /tmp/control.log"

logs_autonomy:
	@$(COMPOSE) exec -T autonomy /bin/bash -lc "tail -n 200 -f /tmp/decision.log"

# --- 模擬 -------------------------------------------------------------------

# 模擬也需要 control 與 autonomy —— sim_launch 會 exec 進那兩個容器。
sim_up: up
	$(COMPOSE) --profile sim up -d --no-build sim

# Gazebo GUI 要能連上 host 的 X server。容器以 root 執行且共用 host 的
# X socket，所以需要一條 local:root 的授權；沒有的話 Qt 會以
# "Authorization required, but no authorization protocol specified" 失敗，
# 接著整個 ign gazebo 程序死掉 —— 表現出來只是「感測器 topic 沒有資料」。
# HEADLESS=true 時不需要。
xhost_grant:
	@if [ "$(HEADLESS)" != "true" ] && [ -n "$(DISPLAY)" ] && command -v xhost >/dev/null 2>&1; then 		xhost +local:root >/dev/null 2>&1 && echo "==> 已授權容器存取 X server（xhost +local:root）" 		|| echo "==> xhost 授權失敗，Gazebo GUI 可能開不起來；可改用 make sim HEADLESS=true"; 	elif [ "$(HEADLESS)" != "true" ] && ! command -v xhost >/dev/null 2>&1; then 		echo "==> 找不到 xhost，Gazebo GUI 可能開不起來；可改用 make sim HEADLESS=true"; 	fi

sim_launch: sim_up xhost_grant
	@echo "==> 啟動 Gazebo（headless=$(HEADLESS)）"
	@$(COMPOSE) exec -T sim /bin/bash -lc "pkill -f '[r]os2 launch' || true; sleep 1" 2>/dev/null || true
	$(COMPOSE) exec -T -d sim /bin/bash -lc "\
		source /opt/ros/humble/setup.bash && source /root/sim_ws/install/setup.bash && \
		exec ros2 launch bringup orca_ros_gz_bridge_launch.py \
			namespace:=$(ORCA_NAMESPACE) headless:=$(HEADLESS) > /tmp/sim.log 2>&1"
	@sleep 8
	@$(MAKE) --no-print-directory launch_control SIM=true
	@$(MAKE) --no-print-directory launch_autonomy

sim: sim_launch
	@sleep 15
	@$(MAKE) --no-print-directory status

# --- 檢查 -------------------------------------------------------------------

status:
	@echo "--- 容器 ---"
	@$(COMPOSE) ps --format '  {{.Name}}\t{{.State}}' 2>/dev/null || true
	@echo ""
	@echo "--- 節點 ---"
	@$(COMPOSE) exec -T control /bin/bash -lc "$(CONTROL_SETUP) \
		ros2 node list 2>/dev/null | LC_ALL=C sort -u | sed 's/^/  /'" 2>/dev/null || echo "  (control 無回應)"
	@echo ""
	@echo "--- 模式 ---"
	@$(COMPOSE) exec -T control /bin/bash -lc "$(CONTROL_SETUP) \
		timeout 5 ros2 topic echo --once /$(ORCA_NAMESPACE)/system_manager/mode std_msgs/msg/String 2>/dev/null | head -1 | sed 's/^/  /'" 2>/dev/null || echo "  (未啟動)"
	@echo ""
	@echo "--- 跨堆疊介面 ---"
	@$(COMPOSE) exec -T control /bin/bash -lc "$(CONTROL_SETUP) \
		echo -n '  wrench_sources/decision : '; \
		timeout 5 ros2 topic info /$(ORCA_NAMESPACE)/control/wrench_sources/decision 2>/dev/null | tr '\n' ' ' || echo '(無)'; echo; \
		echo -n '  targets/depth_m         : '; \
		timeout 5 ros2 topic info /$(ORCA_NAMESPACE)/control/targets/depth_m 2>/dev/null | tr '\n' ' ' || echo '(無)'; echo" 2>/dev/null || true

# 部署前自檢：把最容易靜默失敗的東西一次檢查完。
doctor:
	@echo "--- 環境設定一致性 ---"
	@for svc in control autonomy; do \
		printf '  %-10s ' $$svc; \
		$(COMPOSE) exec -T $$svc /bin/bash -lc \
			'echo "DOMAIN=$$ROS_DOMAIN_ID RMW=$$RMW_IMPLEMENTATION TRANSPORT=$$FASTDDS_BUILTIN_TRANSPORTS"' \
			2>/dev/null || echo "(容器未啟動)"; \
	done
	@echo ""
	@echo "--- 裝置 ---"
	@printf '  STM32 (%s): ' "$(ORCA_STM32_PORT)"
	@$(COMPOSE) exec -T control /bin/bash -lc \
		'[ -e "$(ORCA_STM32_PORT)" ] && echo "存在" || echo "不存在（實機會連不上 STM32）"' 2>/dev/null || echo "(容器未啟動)"
	@echo "  可用的穩定路徑："
	@ls /dev/serial/by-id/ 2>/dev/null | sed 's/^/    /' || echo "    (無 /dev/serial/by-id)"
	@echo ""
	@echo "--- X11（Gazebo GUI 需要）---"
	@printf '  DISPLAY             : %s\n' "$${DISPLAY:-(未設定)}"
	@printf '  容器可連 X server   : '
	@$(COMPOSE) exec -T control /bin/bash -lc \
		'command -v xdpyinfo >/dev/null 2>&1 && (xdpyinfo >/dev/null 2>&1 && echo 可以 || echo "不行（跑 xhost +local:root，或用 HEADLESS=true）") || echo "無法檢測（容器內沒有 xdpyinfo）"' 2>/dev/null || echo "(容器未啟動)"
	@echo ""
	@echo "--- GPU passthrough ---"
	@printf '  nvidia-persistenced : '; systemctl is-active nvidia-persistenced 2>/dev/null || true
	@printf '  容器可見 GPU        : '
	@$(COMPOSE) exec -T autonomy /bin/bash -lc 'nvidia-smi -L 2>/dev/null | head -1 || echo "無（模擬請加 SOFTGL=1）"' 2>/dev/null || echo "(容器未啟動)"
	@echo ""
	@echo "--- bag 空間 ---"
	@df -h $(ORCA_BAG_DIR) 2>/dev/null | tail -1 | sed 's/^/  /' || echo "  (bag 目錄尚未建立)"

clean:
	$(COMPOSE) --profile sim down -v
