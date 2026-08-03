# 全鏈路模擬實測報告

> 日期：2026-08-03
> 環境：x86_64 開發機（20 core / 30 GB RAM / NVIDIA GPU），非 Jetson
> 範圍：SAUVC-Simulation（Gazebo Fortress）＋ SAUVC-RPI（控制堆疊）＋ SAUVC-JETSON（`orca_decision` BT）三個容器同時運行

本文件記錄**實際跑起來**觀測到的行為，與 [REFACTOR_PLAN.md](REFACTOR_PLAN.md) 的靜態分析互補。所有結論都附實測數據。

---

> **後續狀態（2026-08-03）**：本報告列出的問題大多已在同日的重構中修掉。
> 每一節開頭加了狀態標記；修法與驗證見 [REFACTOR_PLAN.md](REFACTOR_PLAN.md)。

## 0. 實測拓撲

| 容器 | 映像 | 內容 |
|---|---|---|
| `orca-auv-gazebo-simulation-container` | `orca-auv-gazebo-simulation-image` | Gazebo Fortress headless + `ros_gz_bridge` + `altimeter_to_pressure_sensor_node` |
| `orca-auv-rpi-ros2-container` | `dianyueguo/orca-auv-rpi-ros2-image` | `simulation_control.launch.py` 全部 15 個節點 |
| `orca-jetson-test` | `isaac_ros_dev-x86_64` | `orca_decision` decision_node（BT `FinalMission`） |

三者皆 `network_mode: host`、`ROS_DOMAIN_ID=0`、`rmw_fastrtps_cpp`。

**結論：三個 container 的介面確實接得起來**，`/orca_auv/control/wrench_sources/decision` 量到 publisher 1 / subscriber 1、穩定 50.000 Hz。深度定深閉迴路可收斂（目標 1.5 m → 穩態 1.501 m）。

---

## 1. 阻斷級問題

### 1.1 跨容器 DDS 發現失敗（Fast DDS 共享記憶體）

**✅ 已修**：設定收斂到 super-repo 的 `.env`，由單一來源注入三個容器；compose 的 fallback 預設值也設成 UDPv4。

**這是目前最該優先解決的問題，且與 REFACTOR_PLAN §3.6 講的 RMW 不一致是「不同的」第二個問題。**

第一次啟動時，RPI 容器內執行 `ros2 node list` **看不到自己啟動的 15 個節點**，只看得到模擬容器的節點；host 上看到的也是同一組。重啟 daemon 後變成只看得到自己的 2 個節點。典型的部分發現（partial discovery）症狀。

根因：兩個容器對 `/dev/shm` 的視野不同 —

| 容器 | `/dev/shm` | `FASTDDS_BUILTIN_TRANSPORTS` |
|---|---|---|
| SAUVC-RPI | compose 掛了 `/dev:/dev`，**等於 host 的 `/dev/shm`** | 未設定 → 預設 `SHM + UDPv4` |
| SAUVC-Simulation | container 自己的（64 MB） | `UDPv4`（compose 已設定） |

Fast DDS 預設會宣告 SHM locator。兩邊 SHM 命名空間不一致時，participant 互相 match 得到、資料卻走不通，且**不會報錯**。

**驗證**：在 RPI 容器加上 `FASTDDS_BUILTIN_TRANSPORTS=UDPv4` 後重啟，全部 19 個節點一次到齊，之後所有測試都正常。

> 影響：合併到同一塊 Orin NX 後，兩個 container 都用 host network，這個問題會 100% 重現。而且它的表現是「靜默失效」——載具只是不動。
>
> 建議：DDS 設定（`RMW_IMPLEMENTATION` / `ROS_DOMAIN_ID` / transport）抽成 super-repo 層級的單一 `.env`，由 compose 注入所有容器。若最後統一到 CycloneDDS，等價設定是關閉 SHM 或給所有容器一致的 `CYCLONEDDS_URI`。

### 1.2 深度 PID 無積分抗飽和、無輸出限幅

**✅ 已修**：新增 `integral_limit` / `output_limit`。同一情境下下沉力停在 57.4 N（原本 119 N 且持續成長），目標拉回後 1 秒內反向出力。

**實測重現**：目標深度設 2.5 m，但水池底在 2.2 m。載具沉到底後：

```
t_s   target  depth    err     sink_N       Fz    thr0..3
 2.5   2.50   1.815   0.685     31.79     41.79   10.45 ...
15.0   2.50   1.815   0.685     57.48     67.48   16.87 ...
30.0   2.50   1.815   0.685     ~90       ~100    ~25   ...
45.0   2.50   1.815   0.685    119.13    129.13   32.28 ...
```

誤差恆定 0.685，積分項**線性成長且無上界**（45 秒內 32 N → 119 N，仍在爬）。四顆垂直推進器各 32 N 並持續上升。

單顆 T200 在 16 V 的上限是 5.25 kgf ≈ 51.5 N（`thruster_lookup_table_16V.csv`）。也就是說再約 60 秒就會全數飽和，而積分項還會繼續累積。此時若把目標深度改淺，PID 需要數十秒的反向誤差才能把積分吐完 → **劇烈上浮超調**。

這不是模擬特有的情境：SAUVC 池深約 2 m，載具觸底、卡住、或浮力配平沒調好，都會產生「誤差恆定不為零」的狀況。

需要補的：
- 積分項 clamp（或 conditional integration / back-calculation anti-windup）
- PID 輸出 clamp
- `wrench_sum` 之後、分配之前的合力限幅

### 1.3 模擬路徑完全沒有推力限幅

**✅ 已修**：限幅移到分配層（實機與模擬的共同節點），並新增 `saturation_mode`（預設 `scale`，保留指令方向）。

實機鏈路是 `分配 → thruster_force_to_pwm_output_signal_node → PWM`，限幅發生在 `thruster_force_to_pwm_output_signal_node`（`np.clip` 到 ±5.25 kgf）。

模擬鏈路刻意跳過該節點，力直接進 `ros_gz_bridge`。因此**模擬中推進器出力無上限**，上面 1.2 的實驗才會看到 32 N 一路往上爬而不飽和。

後果：任何在模擬中調出來的 PID 增益，在實機上會因為飽和而表現不同；模擬也永遠測不到 anti-windup。建議把限幅從 PWM 節點抽出來，變成分配層之後的獨立限幅（實機與模擬共用）。

---

## 2. 架構級缺口

### 2.1 沒有「自主模式」——JETSON 的指令預設是被擋掉的

**✅ 已修**：新增 `AUTONOMOUS` 模式，可與 `DEPTH_HOLD` 疊加，並加上 `decision_timeout_s` 安全檢查（來源逾時直接進 FAULT）。

實測：呼叫 `system_manager/set_mode/safe_disabled` 後 `wrench_sum_node` 進入 `inactive`，`control/wrench_command` 完全停止發布。此時 decision_node 仍在以 50 Hz 發布 wrench，但**完全不會到達推進器**。

`ControlMode` 只有 `SAFE_DISABLED / MANUAL / DEPTH_HOLD / BOTTOM_CAMERA_HOLD / DEPTH_AND_BOTTOM_CAMERA_HOLD / FAULT`。要讓 JETSON 有控制權，必須先進 `MANUAL`（語意矛盾）或 `DEPTH_HOLD`（順帶啟用深度 PID）。

而且 `_set_mode(MANUAL)` 會 `disable_all()` 把深度 PID 關掉，所以「JETSON 開自主 + 深度定深」只有走 `DEPTH_HOLD` 一條路，且沒有任何檢查確認 decision 來源還活著。

**建議**：新增 `AUTONOMOUS` 模式，把 `wrench_sources/decision` 納入 supervisor 的安全檢查（decision 來源 timeout → FAULT），並允許與 depth_hold 疊加。

### 2.2 `targets/depth_m` 有兩個發布者、無仲裁

**⚠️ 未修**：屬跨 repo 介面設計，需與 Autonomy 側一起決定。

實測 `ros2 topic info -v`：

```
PUBLISHER : /decision_node        (JETSON)
PUBLISHER : /orca_auv/gui_node    (操作者)
SUBSCRIBER: /orca_auv/depth_pid_controller_node
SUBSCRIBER: /orca_auv/gui_node
```

兩個權威同時寫同一個 setpoint，最後寫的贏。比賽中操作者從 GUI 拉深度時會與 BT 打架，而且看不出來。

### 2.3 機械臂通道整條斷開（確認）

**⚠️ 未修**：屬 Autonomy 側。

`ros2 topic list` 顯示 `/orca/decision/arm`、`/orca/decision/hand` 只有 JETSON 端 publisher；RPI 端用的是完全不同的 `/orca_auv/actuators/electromagnet/enabled`。中間沒有任何橋接。BT 裡的 `ExtendArm` / `GrabBall` / `RetractArm` / `DropBall` 目前全部是空打。

### 2.4 單位落差（確認，數量級差 2 個量級）

**⚠️ 未修**：屬 Autonomy 側。

decision_node 實測輸出 `torque.z = 0.6 N·m`（`k_yaw 0.3 × yaw 2.0`），力 0 N。同一時間深度 PID 輸出 40–120 N。

`decision_params.yaml` 的 `move_above_max_surge: 15.0`、`bump_flare_surge: 25.0` 對應程式碼預設是 `0.15` / `0.25`；`go_to_pose_surge` 兩邊都是 `0.3`。這些值乘 `k_surge=0.8` 後**直接當牛頓**進分配矩陣，實際後果是 `BumpFlare` 約 20 N（合理）、`GoToPose` 約 0.24 N（等於不動）。

---

## 3. 工程／可維護性問題

### 3.1 容器不是自給自足的——`make init` 裝的東西一 recreate 就沒了

**✅ 已修**：SAUVC-RPI 與 SAUVC-Simulation 的相依都改為裝進映像。

`SAUVC-Simulation` 的 `bringup/package.xml` 依賴 `ros_gz_sim`，但 `Dockerfile` 只裝了 `ros-humble-ros-gz-bridge`。`ros_gz_sim` 是 `make init` 執行 `rosdep install` 時裝進**執行中的容器**的，不在映像裡。

實測：`docker compose down` 後重建容器 → `ros2 pkg prefix ros_gz_sim` 回報 `Package not found`，`make launch` 直接失敗。

同樣的模式在 SAUVC-RPI 也存在（`init` target 跑 `rosdep install`）。這代表「映像 build 成功」不等於「系統能跑」，也代表 CI／新成員上機必然踩坑。

**修法**：所有 rosdep 依賴移進 Dockerfile。

### 3.2 `build/` `install/` 在 bind mount 裡，host build 與容器 build 互相汙染

**✅ 已修**：改用 named volume。

實測第一次 `colcon build` 直接失敗：

```
CMake Error: The current CMakeCache.txt directory /root/rpi_ros2_ws/build/xy_translation_control_interfaces/CMakeCache.txt
is different than the directory /home/huang/workspace/SAUVC/SAUVC-RPI/rpi_ros2_ws/build/xy_translation_control_interfaces
where CMakeCache.txt was created.
```

有人在 host 上 build 過，CMakeCache 記著 host 路徑。因為 `build/` 被 `.gitignore` 忽略，這個狀態不會被任何人發現，只會在下一個人 build 時炸掉。

**修法**：`build/` `install/` `log/` 改用 named volume，或用 `--build-base` / `--install-base` 指到 mount 之外的路徑。

### 3.3 `ros2 launch` 子行程會變孤兒，重啟會疊加多套堆疊

**✅ 已修**：停止流程收斂成單一路徑 pattern，不再逐一列節點名。

實測：`pkill -f simulation_control.launch.py` 只殺掉 launch 母行程，15 個節點全部被 reparent 到 PID 1 繼續跑。接著再 launch 一次 → 同時有兩套 supervisor。

結果是矛盾狀態：`set_mode/depth_hold` 回 `success=True, message='Depth hold active'`、lifecycle 查到 `active`，但 `system_manager/mode` 持續廣播 `SAFE_DISABLED`（另一個 supervisor 在覆蓋）。除錯時極難察覺。

這也解釋了 Makefile 裡那份 17 行的 `pkill` 清單為什麼存在。順帶一提，那份清單本身也有 bug：`pkill -9 -f rpi_ros2_ws/install` 會匹配到執行它的那個 `bash -lc` 自己的命令列而自殺（Makefile 用 `[r]` 括號技巧繞開，但新增節點時很容易忘記照做）。

**修法**：launch 用 process group 管理（`setsid` + `kill -- -PGID`），或把每個堆疊變成獨立的 compose service，用 `docker compose restart` 管理。

### 3.4 REFACTOR_PLAN 未提到的：模擬與實機的深度符號

**⚠️ 未修**：已記錄於 ARCHITECTURE，實機調參時要注意。

`altimeter_to_pressure_sensor_node` 是 `depth_m = -vertical_position`，而 Gazebo altimeter 的 `vertical_position` 是**相對出生點**的。所以模擬的深度零點在載具出生位置（z = -0.40），不是水面。實機的壓力計零點是水面。

模擬調出來的 `depth_force_bias_N` 與絕對深度目標不能直接搬到實機。

---

## 3.5 `wrench_sum` 的 `publish_rate` 參數名不副實

**⚠️ 未修**：不影響正確性，留待後續。

從 bag 量到的實際發布率與設定值不符：`publish_rate` 設 30.0，`control/wrench_command`
實測 197 秒內 9,989 則。

原因在 [wrench_sum_node.py:103](../SAUVC-RPI/rpi_ros2_ws/src/wrench_sum/wrench_sum/wrench_sum_node.py)：
`listener_callback` 收到**任何**來源的訊息就直接呼叫一次 `publish_sum()`，同時
30 Hz 的 timer 也在呼叫。實際輸出率是「timer 頻率 ＋ 所有輸入來源頻率總和」。

對帳（深度定深啟用約 77 秒的區間）：

| 項目 | 則數 | 換算 |
|---|---|---|
| `control/wrench_sources/depth` | 7,684 | 約 100 Hz（等於深度 PID 的迴圈頻率） |
| `control/wrench_command` | 9,989 | ≈ 30 Hz × 77 s + 7,684 = 10,010 ✓ |

後果：下游的分配節點與 PWM 轉換節點實際上以約 130 Hz 在跑，不是設定的 30 Hz；
之後若把 JETSON 的 50 Hz decision 一起接上，會再往上加。在 RPi 上這是效能問題，
搬到 Orin NX 之後主要是「參數說的和實際做的不一致」的維護性問題。

參數集中化（階段 3）時要一併決定：是拿掉 callback 內的直接發布（純 timer 驅動，
語意乾淨），還是把參數改名成反映真實行為。建議前者。

## 4. Repo 體積

| 項目 | 大小 |
|---|---|
| `SAUVC-JETSON/model/`（5 個 `.onnx`） | 214 MB |
| 其中未被任何 config 引用 | `best_conti.onnx`、`best_pretrain.onnx` = 86 MB |
| `SAUVC-JETSON/.git` | 310 MB |

`.onnx` 直接 commit 進 git，每次 clone 都要拉 310 MB。建議改 Git LFS 或 GitHub Release artifact + 啟動時下載。

---

## 5. 重現步驟

```bash
# 1) 模擬
cd SAUVC-Simulation
docker compose -f docker-compose_ubuntu.yml up -d --no-build
docker exec <sim> bash -lc 'apt-get install -y ros-humble-ros-gz-sim'   # ← 3.1 的坑
docker exec -d <sim> bash -lc 'source install/setup.bash && \
  ros2 launch bringup orca_ros_gz_bridge_launch.py namespace:=orca_auv headless:=true'

# 2) 控制堆疊（注意 FASTDDS_BUILTIN_TRANSPORTS）
cd SAUVC-RPI && docker compose up -d --no-build
docker exec <rpi> bash -lc 'cd rpi_ros2_ws && rm -rf build install log && colcon build --symlink-install'
docker exec -d <rpi> bash -lc 'export FASTDDS_BUILTIN_TRANSPORTS=UDPv4 && \
  ros2 launch src/launch/simulation_control.launch.py namespace:=orca_auv'

# 3) 決策層
docker run -d --name jetson --network host --gpus all \
  -e FASTDDS_BUILTIN_TRANSPORTS=UDPv4 \
  -v $PWD/SAUVC-JETSON:/workspaces/isaac_ros-dev/src \
  -w /workspaces/isaac_ros-dev isaac_ros_dev-x86_64:latest sleep infinity
docker exec jetson bash -lc 'colcon build --packages-up-to orca_decision'
docker exec -d jetson bash -lc 'cd src/orca_decision && ros2 launch orca_decision decision.launch.py'

# 4) 驗證
export FASTDDS_BUILTIN_TRANSPORTS=UDPv4
ros2 service call /orca_auv/system_manager/set_mode/depth_hold std_srvs/srv/Trigger '{}'
ros2 topic pub -r 10 /orca_auv/control/targets/depth_m std_msgs/msg/Float64 'data: 1.5'
ros2 topic echo /orca_auv/state/depth_m
```

`decision_node` 的 `tree_xml_file` 是相對路徑 `config/trees.xml`，必須從 `orca_decision/` 目錄啟動，否則載入失敗。這也是一個該修的點。

---

## 6. 後記：GPU passthrough 的坑（2026-08-03 補記）

在 super-repo 的驗證過程中，同一台機器上的 Gazebo 從「可以跑」變成「segfault」。
症狀是**感測器 topic 完全沒有資料、supervisor 停在
`FAULT / Depth sensor data has not been received`** —— 看起來像控制堆疊的問題，
實際上是算繪。

真正的錯誤要往前翻很多行才看得到：

```text
eglInitialize failed for device EGL_EXT_device_drm ... /dev/dri/card2
OpenGL 3.3 is not supported. Please update your graphics card drivers.
Unable to create the rendering window after [11] attempts.
Segmentation fault
```

Gazebo 就算跑 headless（`-s`）也需要算繪，因為世界裡有相機感測器。
GPU passthrough 一壞，世界會開起來、模型也會 spawn，然後整個 `ign gazebo`
程序消失。

根因是 host 的 `nvidia-persistenced` 沒有執行 —— nvidia-container-toolkit 掛
GPU 時會找 `/run/nvidia-persistenced/socket`，找不到就讓容器整個起不來
（任何 `NVIDIA_DRIVER_CAPABILITIES` 組合都一樣）。

處理方式：

1. 新增 `docker-compose.softgl.yml` 作為軟體算繪退路（`make sim SOFTGL=1`）。
   注意 Mesa 的軟體驅動檔名是 `swrast_dri.so`，`MESA_LOADER_DRIVER_OVERRIDE`
   要填 `swrast` 而不是 `llvmpipe`。
2. `/dev/dri` 從 base compose 移到平台疊加檔 —— Ogre 的 EGL 只要看得到 DRM
   device 就會優先用它，而 compose 的 `devices` 是**合併不是覆寫**，
   寫 `devices: []` 清不掉上層定義的裝置。
3. `make doctor` 加上 GPU passthrough 檢查，讓下次遇到時三秒內看得出來。
