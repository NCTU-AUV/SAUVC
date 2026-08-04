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
#   make build_sim   建置 sim_ws（sim 容器內；make sim 會自動先跑）
#   make sim         模擬全鏈路：Gazebo + control(sim) + autonomy
#                    ARENA=finals|qualification  SEED=<int>  HEADLESS=true  SOFTGL=1
#                    DRUM_STYLE=drum|tub|random  RANDOMIZE_WATER=true
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
SIM_WS      := /root/sim_ws

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

# 模擬同樣不能只殺 ros2 launch：parameter_bridge 與 ign gazebo 都是獨立子
# 程序，父程序被殺之後它們會變成孤兒繼續跑。孤兒 bridge 的症狀特別難查 ——
# 重跑一次 make sim 之後每個感測器 topic 就多一個發布者，頻率翻倍而數值本身
# 看起來完全正常（實測 IMU 從 100 Hz 變成 199 Hz）。
STOP_SIM := \
	pkill -INT -f '[r]os2 launch' || true; sleep 2; \
	pkill -9 -f '[p]arameter_bridge' || true; \
	pkill -9 -f '[s]im_ws/install' || true; \
	pkill -9 -f '[i]gn gazebo' || true

.PHONY: all up down build build_sim build_images launch launch_control launch_autonomy stop status \
        sim_up sim sim_launch sim_check xhost_grant logs_control logs_autonomy logs_sim clean doctor \
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

build: up
	@echo "==> colcon build：control"
	$(COMPOSE) exec -T control /bin/bash -lc "\
		cd $(CONTROL_WS) && source /opt/ros/humble/setup.bash && \
		colcon build --symlink-install"
	@echo "==> colcon build：autonomy"
	$(COMPOSE) exec -T autonomy /bin/bash -lc "\
		cd $(AUTONOMY_WS) && source /opt/ros/humble/setup.bash && \
		colcon build --symlink-install"

# sim_ws 不在 build 裡：實機不會啟動 sim 容器，把它加進 build 會強迫
# 載具上多跑一個 Gazebo 容器。改由 sim_launch 自動觸發。
#
# build / install / log 是 named volume（見 docker-compose.yml），映像裡
# 沒有預先 build 過，所以 volume 第一次掛上來是空的 —— 主機上就算 build
# 過也會被蓋掉。少了這一步，sim_launch 的 `source install/setup.bash`
# 會失敗、整串 && 中斷，而 Gazebo 從未啟動。
build_sim: sim_up
	@echo "==> colcon build：sim"
	$(COMPOSE) exec -T sim /bin/bash -lc "\
		cd $(SIM_WS) && source /opt/ros/humble/setup.bash && \
		colcon build --symlink-install"

# --- 啟動 -------------------------------------------------------------------

# SIM=true 時 control 堆疊跑模擬模式（跳過硬體節點）
SIM ?= false
# HEADLESS=true 時 Gazebo 只跑 server，不開 GUI
HEADLESS ?= false

# 感知管線的參數檔。裸檔名由 autonomy.launch.py 解析到 orca_perception/config，
# 所以這裡不必寫 install space 的完整路徑。留空 = 用管線預設（實機話題）。
PERCEPTION_CONFIG ?=
# PERCEPTION=false 只啟動行為樹。單純除錯 BT 時才關，正常不要動 ——
# 關掉之後世界模型會是空的，所有搜尋／接近節點都會跑到逾時。
PERCEPTION ?= true

AUTONOMY_LAUNCH_ARGS := use_perception:=$(PERCEPTION)
ifneq ($(strip $(PERCEPTION_CONFIG)),)
AUTONOMY_LAUNCH_ARGS += perception_config:=$(PERCEPTION_CONFIG)
endif

# 模擬場地：finals（決賽，道具位置與 drum 順序每次隨機）或
# qualification（資格賽，只有起始線隨機）。
ARENA ?= finals
# 亂數種子。給定時佈局完全可重現 —— 除錯時務必給，否則重啟一次道具就跑掉，
# 前一次的 bag 也對不起來。不給則每次都不同（測 BT 泛用性用）。
SEED ?=

# 目標容器形狀：drum（rulebook 文字的圓桶）/ tub（比賽照片的方形塑膠箱）/ random。
# 主辦單位兩種都用過，random 讓一次跑動涵蓋兩種外觀。
DRUM_STYLE ?= random
# 讓水質、能見度與曝光隨時間變化，而不是固定一種水況。
RANDOMIZE_WATER ?= false

SIM_LAUNCH_ARGS := arena:=$(ARENA) drum_style:=$(DRUM_STYLE) randomize_water:=$(RANDOMIZE_WATER)
ifneq ($(strip $(SEED)),)
SIM_LAUNCH_ARGS += seed:=$(SEED)
endif

launch: launch_control launch_autonomy
	@echo "節點啟動中，用 make status 查看"

launch_control: up
	@echo "==> 啟動 control 堆疊（sim=$(SIM)）"
	@$(COMPOSE) exec -T control /bin/bash -lc "$(STOP_CONTROL)" >/dev/null 2>&1 || true
	$(COMPOSE) exec -T -d control /bin/bash -lc "\
		$(CONTROL_SETUP) \
		exec ros2 launch orca_bringup bringup.launch.py sim:=$(SIM) > /tmp/control.log 2>&1"

# autonomy.launch.py 同時拉起感知管線與決策節點。不要改回
# decision.launch.py —— 那個只有行為樹，沒有任何節點發布
# /orca/perception_array，世界模型會永遠是空的。
launch_autonomy: up
	@echo "==> 啟動 autonomy 堆疊（perception=$(PERCEPTION)$(if $(strip $(PERCEPTION_CONFIG)), config=$(PERCEPTION_CONFIG)))"
	@$(COMPOSE) exec -T autonomy /bin/bash -lc "$(STOP_AUTONOMY)" >/dev/null 2>&1 || true
	@# decision_node 的 tree_xml_file 是相對路徑 config/trees.xml，
	@# 必須從 orca_decision 目錄啟動，否則 BehaviorTree 載入失敗。
	$(COMPOSE) exec -T -d autonomy /bin/bash -lc "\
		$(AUTONOMY_SETUP) cd src/orca_decision && \
		exec ros2 launch orca_decision autonomy.launch.py \
			$(AUTONOMY_LAUNCH_ARGS) > /tmp/autonomy.log 2>&1"

stop:
	@echo "==> 停掉所有 ROS 節點"
	-@$(COMPOSE) exec -T control  /bin/bash -lc "$(STOP_CONTROL); ros2 daemon stop || true" 2>/dev/null
	-@$(COMPOSE) exec -T autonomy /bin/bash -lc "$(STOP_AUTONOMY); ros2 daemon stop || true" 2>/dev/null
	@# sim 容器多半沒在跑（實機不啟動），失敗是正常的。
	-@$(COMPOSE) exec -T sim /bin/bash -lc "$(STOP_SIM); ros2 daemon stop || true" 2>/dev/null
	@echo "已停止"

logs_control:
	@$(COMPOSE) exec -T control /bin/bash -lc "tail -n 200 -f /tmp/control.log"

logs_autonomy:
	@$(COMPOSE) exec -T autonomy /bin/bash -lc "tail -n 200 -f /tmp/autonomy.log"

logs_sim:
	@$(COMPOSE) exec -T sim /bin/bash -lc "tail -n 200 -f /tmp/sim.log"

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

sim_launch: build_sim xhost_grant
	@echo "==> 啟動 Gazebo（arena=$(ARENA) seed=$(if $(strip $(SEED)),$(SEED),隨機) headless=$(HEADLESS) drum_style=$(DRUM_STYLE) randomize_water=$(RANDOMIZE_WATER)）"
	@$(COMPOSE) exec -T sim /bin/bash -lc "$(STOP_SIM)" >/dev/null 2>&1 || true
	$(COMPOSE) exec -T -d sim /bin/bash -lc "\
		source /opt/ros/humble/setup.bash && source $(SIM_WS)/install/setup.bash && \
		exec ros2 launch bringup orca_ros_gz_bridge_launch.py \
			namespace:=$(ORCA_NAMESPACE) headless:=$(HEADLESS) \
			$(SIM_LAUNCH_ARGS) > /tmp/sim.log 2>&1"
	@$(MAKE) --no-print-directory sim_check
	@$(MAKE) --no-print-directory launch_control SIM=true
	@$(MAKE) --no-print-directory launch_autonomy PERCEPTION_CONFIG=simulation_params.yaml

# exec -T -d 會丟掉 ros2 launch 的離開碼，所以「Gazebo 根本沒起來」必須
# 另外偵測 —— 否則 make sim 會在空池的情況下一路跑完並回傳 0，只在容器裡
# 的 /tmp/sim.log 留下痕跡。用感測器 topic 當就緒訊號：它同時證明 Gazebo、
# 世界、模型與 bridge 四者都活著。
#
# 判斷條件必須是「真的收到一則訊息」。另外兩種寫法都會漏掉真實的失敗：
#   ros2 topic list  —— control 與 autonomy 都訂閱這個 topic，它們活著就列得出來
#   Publisher count  —— ros_gz_bridge 是獨立程序，Gazebo 死了它照樣掛著發布者
# 兩者都會在「Gazebo 已經死掉」時回報就緒，正是這個檢查要防的情況。
SIM_READY_TIMEOUT ?= 90
sim_check:
	@echo "==> 等待模擬就緒（最多 $(SIM_READY_TIMEOUT) 秒）"
	@$(COMPOSE) exec -T sim /bin/bash -lc '\
		source /opt/ros/humble/setup.bash; source $(SIM_WS)/install/setup.bash; \
		for i in $$(seq 1 $(SIM_READY_TIMEOUT)); do \
			if timeout 2 ros2 topic echo --once \
			   /$(ORCA_NAMESPACE)/sensors/imu >/dev/null 2>&1; then \
				echo "    模擬已就緒（約 $${i}s）"; exit 0; \
			fi; \
		done; \
		echo "    模擬未在時限內就緒（$(ORCA_NAMESPACE)/sensors/imu 沒有資料）。"; \
		echo "    /tmp/sim.log 末 40 行："; \
		tail -n 40 /tmp/sim.log 2>&1 | sed "s/^/    /"; \
		exit 1'

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
