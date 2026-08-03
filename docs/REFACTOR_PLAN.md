# SAUVC-RPI 重構計畫書

> 狀態：**SAUVC-RPI 階段 0–5 完成；super-repo 與 Isaac 映像瘦身亦已完成**（2026-08-03）
> 撰寫日期：2026-07-25／決策定案與開工：2026-08-03
> 適用範圍：`rpi_ros2_ws` 底下的 ROS 2 packages 與 launch / 設定 / 容器組態
>
> 相關文件：[SIMULATION_FINDINGS.md](SIMULATION_FINDINGS.md) —— 三容器全鏈路實測報告，
> 本計畫書的多項假設已由該次實測驗證或修正，見 §7 決策紀錄。

---

## 目錄

1. [計畫背景與大方向](#1-計畫背景與大方向)
2. [本次範圍與不在範圍內的事](#2-本次範圍與不在範圍內的事)
3. [現況問題盤點](#3-現況問題盤點)
4. [目標架構](#4-目標架構)
5. [分階段執行計畫](#5-分階段執行計畫)
6. [風險與回退策略](#6-風險與回退策略)
7. [決策紀錄](#7-決策紀錄2026-08-03-定案)
8. [super-repo](#8-super-repo2026-08-03-完成)
9. [Isaac ROS 映像](#9-isaac-ros-映像2026-08-03-完成)
10. [尚未完成](#10-尚未完成)

---

## 1. 計畫背景與大方向

### 1.1 上位計畫

本次重構是一個更大整併計畫的第一步。整體方向已確認如下：

| 項目 | 決定 |
|---|---|
| 硬體拓撲 | **Raspberry Pi 完全移除**，STM32 改為直接以 USB 接上 Jetson Orin NX |
| 執行平台 | JETSON 與 RPI 兩套堆疊都跑在**同一塊 Jetson Orin NX** 上 |
| 容器策略 | **維持兩個獨立 container**，由一個新的 super-repo 以單一 compose 同時啟動 |
| Repo 組織 | 新建 super-repo，以 submodule 方式納入 SAUVC-JETSON / SAUVC-RPI / SAUVC-Simulation |
| Isaac ROS | **留在 3.2 / JetPack 6 / Humble**，先做映像檔瘦身，不升級 4.x |
| RealSense | 實機會用，realsense 映像層必須保留 |

維持兩個 container 而非合併的理由：兩者 base image 無法調和（CUDA devel + Isaac ROS 全家桶 vs 乾淨的 `ros:humble`）；改動頻率差距極大（控制堆疊天天調參，Isaac 映像半年不動）；故障隔離（感知 OOM / GPU 異常不應拖垮推進器控制）。

### 1.2 RPi 移除對本 repo 的直接衝擊

這是本次重構最重要的前提變更，會滲透到下面每一個階段：

1. **本 repo 的定位改變。** 它不再是「跑在樹莓派上的程式」，而是「載具控制堆疊（vehicle control stack）」，只是剛好被包在自己的 container 裡。README、ARCHITECTURE.md 的敘述、乃至 repo 名稱都需要重新檢視。
2. **序列埠假設全部要重驗。** `micro_ros_agent` 的 `/dev/ttyUSB0`、`stm32_flasher_node` 的 ST-Link、`mavros` 的 `/dev/ttyACM0`，全部從 RPi 的 USB 換成 Jetson 的 USB。裝置節點編號在新主機上不保證相同，硬編碼路徑必須改成可設定，並優先改用 `by-id` 穩定路徑。
3. **RMW 必須統一，且這件事變成阻斷性問題。** 現況兩邊不一致：
   - Isaac ROS 側：[run_dev.sh:232](../../SAUVC-JETSON/isaac_ros_common/scripts/run_dev.sh) 寫死 `rmw_cyclonedds_cpp`
   - 本 repo 側：[docker-compose.yml:17](../docker-compose.yml) 與 Makefile 用 `rmw_fastrtps_cpp`

   跨 DDS 廠商透過 RTPS 互通在 ROS 2 理論上可行、實務上極不可靠。過去雙板架構下就已經有這個問題（值得回頭確認實機上 `wrench_sources/decision` 是否真的通過）；改成同一塊板子後，兩個 container 都用 host network，這個不一致會直接讓兩邊看不到彼此。
4. **底部相機確定退場。** JETSON 側的 `camera_selector` 已有自己的 USB 底部相機輸入路徑，本 repo 的 `bottom_camera` package 在合併後完全重複。
5. **運算資源特性改變。** Orin NX 的 CPU 遠強於 RPi，Python 節點的負擔不再是瓶頸；但要與 YOLOv8 / TensorRT 推論搶 CPU，因此「砍掉不必要的節點」的價值從「效能必要」轉為「可維護性」。
6. **GUI 存取位址改變。** 原本的 `raspberrypi.local` 不再存在。

---

## 2. 本次範圍與不在範圍內的事

### 2.1 本次要做（SAUVC-RPI 內部）

- 砍掉非主線 component，保留主線：接收 JETSON 的 `wrench_sources/decision` 與 `targets/depth_m`，用 PID 達成目標，並維持其餘感測器 topic
- 光流（LK optical flow）相關介面全部移除，以 legacy 形式保留原始碼
- 建立集中式 config 檔，讓需要反覆調適的參數在啟動時讀取，且盡量支援執行期熱調
- 導入 bag 錄製機制
- ROS 2 package 與 node 的重新整理

### 2.2 原本不在範圍、後來一併完成的事

計畫書撰寫時列為「本次不做」，實際執行時因為與本次產出直接相依而一併完成：

- **super-repo 與 submodule 骨架**（見 §8）
- **Isaac ROS 映像瘦身與 registry 預建**（見 §9）
- **SAUVC-Simulation 的映像自給自足**（與本 repo 同一類問題）

仍然不做：JETSON 側感知／決策**程式碼**的修改、Humble → Jazzy 遷移。

原則：本次的所有產出都必須讓後續整併更容易，不得增加整併難度。具體來說 — 參數要能被外部 compose 覆寫、裝置路徑不得硬編碼、RMW 設定要能從單一來源注入。

---

## 3. 現況問題盤點

### 3.1 砍光流會連帶砍掉整條 xy_control 鏈

[lk_total_transform_node.py](../rpi_ros2_ws/src/xy_control/xy_control/lk_total_transform_node.py)（1,396 行、約 70 個參數）是以下四個 topic 的**唯一發布者**：

- `camera/bottom/pose_px`
- `control/pid/bottom_camera/x/feedback_px`
- `control/pid/bottom_camera/y/feedback_px`
- `state/bottom_camera/yaw_rad`

因此移除它會讓下列全部失去輸入而成為死碼：

| 對象 | 說明 |
|---|---|
| x / y / yaw 三個 PID 實例 | 沒有 feedback |
| `bottom_camera_pid_bridge_node` | 三軸輸出無來源 |
| `yaw_reference_unwrapper_node` | 同上 |
| `waypoint_target_publisher` + `MoveToPoint` action | 目標是像素座標 |
| `xy_translation_control_interfaces`（整個 package） | 只定義 `MoveToPoint.action` |
| `dive_then_forward_mission_node`（1,093 行） | 依賴上述全部 |
| supervisor 的 `bottom_camera_pid_fbc` 群組 | 含 `BOTTOM_CAMERA_HOLD`、`DEPTH_AND_BOTTOM_CAMERA_HOLD` 兩個模式與 `bottom_camera_ready()` 安全檢查 |
| `gui_node` 約三分之一邏輯 | [protocol.py](../rpi_ros2_ws/src/gui/gui/backend/protocol.py) 有 8 個 bottom-camera topic 常數 |

**合計約 3,000+ 行，佔 workspace 約 40%。** 好消息是主線（深度 + wrench bus + 推力分配）與這條鏈完全解耦，切面乾淨。

### 3.2 砍完之後只剩一個 PID 在運作

需要先講清楚，因為它決定這次重構的實質內容：

- `wrench_sources/decision` 送來的**已經是 Wrench**，直接進 `wrench_sum`，**完全不經過 PID**。JETSON 的 BT 自行計算 surge / sway / yaw，只做低通濾波。
- `targets/depth_m` 是唯一走 PID 的通道。

換言之，重構後「用 PID 控制達到目標」字面上**只剩深度軸**，yaw 將變成全開迴路。而本 repo 手上已經有 IMU（`sensors/imu` → `state/orientation`，目前僅被深度力方向使用且預設關閉）。

**建議**：新增一個以 IMU yaw 為回饋的 yaw-hold PID，複用同一份 `generic_pid_controller_node`，新增 `control/targets/yaw_rad` 介面，輸出到 `control/wrench_sources/yaw`。因為是 wrench bus 架構，它與 JETSON 現有的 yaw 指令**可以並存**，依情境擇一使用，不需要改 JETSON。

### 3.3 參數散落且已經互相矛盾

| 問題 | 位置 |
|---|---|
| `depth_force_bias_N` 節點預設 `5.0`，launch 設 `10.0` | [output_sink...node.py:32](../rpi_ros2_ws/src/depth_control/depth_control/output_sink_force_to_output_wrench_node.py) vs [depth_control_launch.py:38](../rpi_ros2_ws/src/depth_control/launch/depth_control_launch.py) |
| `wrench_sum` 設定出現在 3 個地方且內容不一致 | 節點預設只有 gui + bottom_camera；`orca_bringup.launch.py`；`simulation_control.launch.py` |
| 推進器幾何矩陣硬編碼 | [wrench_to_individual...node.py:40-49](../rpi_ros2_ws/src/thrusters/thrusters/wrench_to_individual_thrusters_output_forces_node.py) |
| 裝置路徑硬編碼 | `orca_bringup.launch.py` 的 `/dev/ttyUSB0`、`/dev/ttyACM0` |
| PID 增益硬編碼在 launch dict | `bottom_camera_pid_fbc_launch.py`、`depth_control_launch.py` |

`simulation_control.launch.py` 基本上是 `orca_bringup.launch.py` 的複製貼上分支，兩者已經開始漂移。

### 3.4 目前沒有任何 bag 錄製機制

三個 repo 全域搜尋 `ros2 bag` / `rosbag2` / `SequentialWriter` 均無結果。

### 3.5 節點歸屬不合理

`imu_to_orientation_node` 放在 `depth_control` package 裡，但它與深度無關；`float32_to_float64_converter_node` 是通用型別轉換。兩者都應歸入感測器層。

### 3.6 跨 repo 介面落差（記錄備查，本次不修 JETSON）

這幾點在合併到同一塊板子後會更容易踩到，先記錄：

1. **單位不一致，且 YAML 與程式碼預設差 100 倍。** [decision_params.yaml](../../SAUVC-JETSON/orca_decision/config/decision_params.yaml) 的 `move_above_max_surge: 15.0`、`bump_flare_surge: 25.0`，對應 [decision_node.cpp](../../SAUVC-JETSON/orca_decision/src/decision_node.cpp) 預設是 `0.15`、`0.25`；偏偏 `go_to_pose_surge` 兩邊都是 `0.3` 未調整。這些值乘上 `k_surge` 後**直接當牛頓**進入本 repo 的分配矩陣。實際後果：`BumpFlare` 出約 20 N，`GoToPose` 出約 0.24 N（等於不動）。
2. **`heave` 無增益且無人設定。** [wrench_adapter.cpp:33](../../SAUVC-JETSON/orca_decision/src/wrench_adapter.cpp) 的 `force.z = heave` 是唯一沒乘係數的軸。目前所有 BT 節點都未設定 heave，故恆為 0；但一旦有人設定，它會**直接對抗深度 PID**，且兩者都在 wrench bus 上靜默相加。
3. **機械臂通道整條斷開。** JETSON 發布 `/orca/decision/arm`(Int32) 與 `/orca/decision/hand`(Bool)，`decision.launch.py` 未 remap 這兩個，本 repo 也無任何訂閱者。本 repo GUI 用的是完全不同的名字 `actuators/electromagnet/enabled`。
4. **無回饋回 JETSON。** JETSON 設定 desired_depth 但從不知道實際深度。
5. **兩個獨立的 IMU 來源。** JETSON 的 `orca_decision` 訂閱 `/orca/imu/data`（飛控 / MAVROS），本 repo 的 `imu_to_orientation_node` 訂閱 `sensors/imu`（STM32）。合併到同一塊板子後，同一台載具上兩個 IMU 各餵各的消費者，彼此不知道對方存在。**若採納 3.2 的 yaw PID 建議，必須先決定 yaw 的權威來源是哪一個。**
6. **namespace 硬編碼。** JETSON 寫死 `/orca_auv/...`，本 repo 的 namespace 是 launch 參數。改動後 JETSON 會靜默失效（wrench_sum 的 timeout 會把該來源歸零，載具只是不動，沒有錯誤訊息）。

---

## 4. 目標架構

### 4.1 Package 佈局

```
rpi_ros2_ws/src/
├── orca_bringup/          # 新增：所有 launch + config（唯一設定來源）
│   ├── launch/orca_bringup.launch.py
│   ├── launch/simulation.launch.py
│   ├── launch/record.launch.py
│   └── config/
│       ├── orca_params.yaml       # 控制參數（會反覆調適的）
│       ├── hardware.yaml          # 裝置路徑、推進器幾何
│       ├── record_topics.yaml     # bag 錄製清單
│       └── sim_overrides.yaml     # 模擬用疊加值
├── control/               # 保留：generic_pid_controller_node
├── sensors/               # 新增：float32→64、imu→orientation（從 depth_control 拆出）
├── depth_control/         # 瘦身：僅保留 sink_force → wrench（+ math_utility）
├── wrench_sum/            # 保留
├── thrusters/             # 保留（幾何移入 config）
├── system_manager/        # 瘦身：移除 bottom_camera 群組與相關模式
├── stm32_manager/         # 保留
├── gui/                   # 瘦身：移除 bottom-camera 面板
└── legacy/                # 內含空的 COLCON_IGNORE，不編譯、不啟動
    ├── xy_control/
    ├── bottom_camera/
    └── xy_translation_control_interfaces/
```

`src/legacy/COLCON_IGNORE` 會讓 colcon 跳過整個子樹，原始碼仍留在 git 中可供查閱。這正是「當作 legacy 放著」的標準做法。

### 4.2 集中式參數設計

**ROS 2 namespace 陷阱**：params YAML 的 key 必須是含 namespace 的完整節點名。因為本專案 namespace 是 launch 參數，必須使用萬用字元寫法，否則會綁死：

```yaml
/**/depth_pid_controller_node:
  ros__parameters:
    proportional_gain: 40.0
    integral_gain: 3.0
    derivative_gain: 12.0
    derivative_smoothing_factor: 0.0
```

**必須在文件中區分兩類參數**：

| 類別 | 行為 | 例子 |
|---|---|---|
| 熱調（`ros2 param set` 立即生效） | 每個控制迴圈重新讀取 | PID 四個增益、`depth_force_bias_N` |
| 開機才讀（改了要重啟） | 建構時讀一次 | `controller_loop_timer_period_s`、`wrench_sum` 的 `input_topics` / `publish_rate` / `source_timeout_s` |

PID 增益在 [generic_pid_controller_node.py:142-151](../rpi_ros2_ws/src/control/control/generic_pid_controller_node.py) 是每迴圈重讀，這個設計是池邊調參的命脈，**必須保留**，不可為了效能改成快取。

另外規劃一個 `make dump_params` 目標，把當前執行中的參數 `ros2 param dump` 回寫 YAML — 池邊調了兩小時的成果不應該靠手抄。

### 4.3 Bag 錄製設計

考量到 Jetson 的實務條件：

| 決策 | 理由 |
|---|---|
| 預設**不錄影像**，影像另開 flag 且只錄 compressed | 原始影像會吃爆儲存並拖垮 I/O |
| 用 **mcap** storage，不用預設 sqlite3 | AUV 靠 kill switch 斷電關機，sqlite3 遇硬斷電容易整包損毀；mcap 對截斷友善。套件：`ros-humble-rosbag2-storage-mcap` |
| `--max-bag-duration` 分段 | 最壞只損失最後一段 |
| bag 落地到獨立掛載的 volume，並加入 `.gitignore` | 現行 compose 只掛了 workspace |
| 隨 bringup 自動開始錄，用 launch 參數關閉 | 比賽時沒有人會記得按錄影 |
| 啟動前檢查剩餘空間，低於門檻則不啟動並警告 | 避免寫滿系統碟 |

實作方式：在 bringup launch 中以 `ExecuteProcess` 執行 `ros2 bag record`，topic 清單讀取同一份 config。約 15 行，不需要新增 package。若日後需要「標記某一趟」再加上 service 控制的 recorder node。

---

## 5. 分階段執行計畫

每個階段都必須獨立可驗證、可回退。**順序刻意讓 bag 錄製排在最前面**，如此後續每一次刪除都有重構前的實際資料可比對。

### 階段 0：基準線與環境對齊 —— ✅ 已完成（2026-08-03）

| 項目 | 內容 |
|---|---|
| 產出 | `docs/baseline/`：19 節點 / 55 topic / 155 service / 15 個節點的 `ros2 param dump` |
| 動作 | 新增 `.env` 作為 ROS/DDS 設定的唯一來源，compose 與 Makefile 都從它取值 |
| 動作 | `build/` `install/` `log/` 改用 named volume，杜絕 host build 與容器 build 互相汙染 |
| 動作 | Dockerfile 補上全部 workspace 執行期相依，容器不再需要靠 `make init` 的 `rosdep install` 才能跑 |
| 動作 | Makefile 的 17 行 pkill 清單收斂成單一 pattern `[r]pi_ros2_ws/install`，新增節點不會再漏 |
| 驗證 | 全新容器（不做任何 apt/rosdep）→ `colcon build` 11 個 package 通過 → bringup 節點清單與基準線**逐行一致** |

發現並修掉的自傷：在 micro-ROS 那層之前加 `rm -rf /var/lib/apt/lists/*`，會讓
`rosdep install` 內部的 `apt-get install` 以 `Unable to locate package` 失敗。
每個會裝東西的 `RUN` 都必須自帶 `apt-get update`。

### 階段 1：導入 bag 錄製 —— ✅ 已完成（2026-08-03）

| 項目 | 內容 |
|---|---|
| 動作 | 新增 `orca_bringup` package（同時是階段 3 集中式設定的落腳處）、`config/record_topics.yaml`、`launch/record.launch.py`、compose bag volume、`.gitignore` |
| 動作 | 兩個 bringup launch 都加上 `record` / `record_images` 參數，預設隨啟動自動錄 |
| 驗證 | 29 個 topic 錄製中；mcap 分段每 120 s 一檔；空間檢查讀到實際掛載點；topic 清單與基準線的差集**恰好只有 rosbag2 自己的 `/events/write_split`** |
| 驗證 | **硬斷電情境**：SIGKILL recorder 後 `metadata.yaml` 不存在、`ros2 bag info` 打不開，但 `ros2 bag reindex -s mcap` 可完整搶救（18.1 MiB / 197 s / 主線 topic 齊全）。這是選 mcap 而非 sqlite3 的理由，現已實證 |
| 風險 | 低。完全是加法 |

> **維運須知**：AUV 靠 kill switch 斷電後，bag 目錄不會有 `metadata.yaml`，
> 這是正常的，不代表資料遺失。撈資料前先跑一次：
> `ros2 bag reindex <bag_dir> -s mcap`
>
> 另：容器以 root 執行，落地的 bag 在 host 上屬 root。撈檔案需要 `sudo chown`，
> 這點在階段 3 一併處理（改用 `user:` 或啟動時 chown）。

### 階段 2：光流線移入 legacy + supervisor / GUI 同步瘦身

| 項目 | 內容 |
|---|---|
| 動作 | `xy_control`、`bottom_camera`、`xy_translation_control_interfaces` 移入 `src/legacy/` 並加 `COLCON_IGNORE`；supervisor 移除 `bottom_camera_pid_fbc` 群組、兩個相關模式與 `bottom_camera_ready()`；GUI 移除 bottom-camera 面板與相關 protocol 常數；清理 Makefile 中大量的 `pkill` 清單 |
| 驗證 | 全新 `colcon build` 通過；bringup 啟動後節點清單與階段 0 快照的差集**恰好等於**預期刪除清單，無非預期缺漏；深度定深功能實測不受影響 |
| 回退 | 移除 `COLCON_IGNORE` 並還原 supervisor / GUI 兩個檔案 |
| 風險 | 中。**supervisor 與 GUI 必須與刪除同批進行**，否則 supervisor 會持續對不存在的節點呼叫 lifecycle（不會崩潰，但會刷警告並讓狀態機邏輯失真） |

### 階段 3：參數集中化 —— ✅ 已完成（2026-08-03）

| 項目 | 內容 |
|---|---|
| 動作 | 所有 launch 搬進 `orca_bringup`，刪除 `src/launch/`、`thrusters/launch/`、`wrench_sum/launch/`、`depth_control/launch/` |
| 動作 | 抽出 `orca_params.yaml`（控制參數）與 `hardware.yaml`（推進器幾何、出力上限、ESC 時序） |
| 動作 | **實機與模擬合併成同一個 `bringup.launch.py`**，用 `sim:=true` 切換，差異只有「跳過硬體節點」＋疊上 `sim_overrides.yaml` |
| 動作 | 裝置路徑改為可設定（`.env` 的 `ORCA_STM32_PORT`），並在文件中要求優先用 `/dev/serial/by-id/` 穩定路徑 |
| 驗證 | `make dump_params` 確認 10 個節點的參數全部來自 YAML，含 sim 疊加值（`require_not_killed: false` 等）確實生效，沒有靜默回落到節點預設 |
| 驗證 | 節點清單與階段 2 完全一致 —— 純重組，沒有動到任何節點名 |

設計取捨：**裝置路徑放 `.env`，控制參數放 YAML**。理由是 compose 也要用同一份
裝置路徑去掛裝置，寫在 ROS 參數檔會變成兩個來源必然漂移。原草案規劃把裝置路徑
放進 `hardware.yaml`，實作時改掉了。

原草案的 `simulation.launch.py` 沒有實作 —— 一個 launch 檔 + `sim` 開關比兩個
檔案更難漂移，而且對使用者來說也更直觀。

### 階段 4：Package 重組與行為修正 —— ✅ 已完成（2026-08-03）

| 項目 | 內容 |
|---|---|
| 動作 | 新增 `sensors` package：`float32_to_float64_converter_node`、`imu_to_orientation_node` 從 `depth_control` 拆出 |
| 動作 | `depth_control` 瘦身為只剩 `output_sink_force_to_output_wrench_node` + `math_utility` |
| 動作 | 推進器幾何移入 `hardware.yaml`，不再硬編碼 |
| 動作 | GUI 移除 process 管理功能（`subprocess.Popen` 啟停 launch 檔）—— supervisor 已經用 lifecycle 管理節點，這是更早期的殘留 |

**三項行為修正**（決策見 §7.3）：

1. **PID 積分抗飽和 + 輸出限幅。** 新增 `integral_limit` / `output_limit`
   兩個熱調參數（`<= 0` 停用）。`integral_limit` 限制的是積分項的輸出貢獻，
   單位與 `output_limit` 一致（牛頓），觸限時把內部累加值倒算回邊界。

   驗證（重現原始失控情境，目標 2.5 m / 池底 2.2 m）：

   | | 重構前 | 重構後 |
   |---|---|---|
   | 45 秒時的下沉力 | 119 N 且持續線性成長 | 57.4 N 穩定（= P 27.4 + I 上限 30.0）|
   | 推進器出力 | 32 N 且持續成長 | 精準停在 15.00 N |
   | 目標拉回 1.0 m 後的反應 | 積分要吐幾十秒 | 1 秒內就反向出力 |

2. **推力限幅移到分配層。** 從 `thruster_force_to_pwm_output_signal_node`
   移到 `wrench_to_individual_thrusters_output_forces_node`，因為後者是實機與
   模擬的共同節點。PWM 節點的 clamp 保留為最後防線。

   > **偏離原決策**：原本選的是「抽成獨立節點」。實作時改成放進分配節點，
   > 因為獨立節點需要 8 個訂閱 + 8 個發布的純轉發層，與「最小可運行架構」
   > 相衝突，而放進分配節點同樣達成「模擬與實機共用同一組飽和行為」這個
   > 真正的目的。
   >
   > **另一個行為變更需要水池驗證**：新增 `saturation_mode`，預設 `scale`
   > （任一顆超限時全部等比例縮放，保留指令方向）而非舊有的 `clip`
   > （各自截斷，會扭曲合力方向）。這在實機上是行為變更。

3. **新增 `AUTONOMOUS` 模式。** 可與 `DEPTH_HOLD` 疊加。新增
   `decision_timeout_s` 安全檢查：decision wrench 逾時直接進 `FAULT`，
   而不是讓 `wrench_sum` 靜默歸零。

   驗證（接真的 `orca_decision` BT）：`set_mode/autonomous` → 模式
   `AUTONOMOUS`、`wrench_sum` active、decision 的 `torque.z 0.6` 確實穿到
   `thruster_4`；疊加 depth_hold → `AUTONOMOUS_AND_DEPTH_HOLD`；
   殺掉 `decision_node` → 1 秒內進 `FAULT`（狀態訊息 `Decision wrench is stale`）
   並停掉 `wrench_sum`。

### 階段 5：文件更新 —— ✅ 已完成（2026-08-03）

改寫 `README.md`（定位、設定放哪、操作指令、控制模式、bag 搶救步驟）與
`docs/ARCHITECTURE.md`（移除感知層與 xy_control 章節、補上 wrench 匯流排、
AUTONOMOUS 模式、參數 namespace 陷阱、模擬深度零點差異、跨 repo 已知問題）。

### 未納入本次：IMU yaw PID

光流退場後 yaw 是全開迴路（由 Autonomy 的 wrench 直接驅動）。要補 yaw-hold
可複用同一份 `generic_pid_controller_node`，但需先決定 yaw 的權威來源是
STM32 IMU 還是飛控 IMU（見 §3.6 第 5 點）。這是唯一新增控制行為、需要實機
調參的項目，獨立成後續工作。


## 6. 風險與回退策略

| 風險 | 影響 | 緩解 |
|---|---|---|
| RMW 不一致未先解決就開始重構 | 兩個 container 看不到彼此，所有整合測試結果都不可信 | **階段 0 必須先解決**，這是所有後續驗證的前提 |
| 刪除範圍誤判，砍到主線用到的東西 | 深度控制失效 | 以階段 0 的節點 / topic 快照做差集比對，不靠人工檢查 |
| 參數 YAML namespace 寫錯，靜默回落預設值 | PID 增益變成 0，載具不動或行為異常 | 強制 `ros2 param dump` 逐字比對 |
| 裝置路徑在 Jetson 上編號不同 | micro-ROS agent 連不上 STM32，全系統無感測 | 改用 `by-id` 穩定路徑，並在 bringup 加開機自檢 |
| bag 寫滿儲存空間 | 系統碟滿，可能導致其他寫入失敗 | 啟動前空間檢查 + 分段 + 獨立 volume |
| 重構期間需要出水池測試 | 半成品狀態無法測試 | 每個階段結束都必須是可下水的完整狀態；不允許跨階段的半完成狀態進主分支 |

**總體回退原則**：每個階段一個獨立 commit / PR，階段之間系統都處於可運作狀態。`legacy/` 保留原始碼而非刪除，任何時候都能把光流鏈接回來。

---

## 7. 決策紀錄（2026-08-03 定案）

1. **DDS 統一方案：Fast DDS + `FASTDDS_BUILTIN_TRANSPORTS=UDPv4`。**

   原草案建議改用 CycloneDDS。實測後改變結論：真正會咬人的不是 RMW 廠商不一致，而是
   **Fast DDS 的共享記憶體傳輸在跨 container 時靜默失效**（見 SIMULATION_FINDINGS §1.1）。
   本 repo 的 compose 掛載 host `/dev`（含 `/dev/shm`），與其他 container 的 SHM
   命名空間不一致，participant 會 match 到但資料走不通且不報錯。

   採 Fast DDS + UDPv4 的理由：已用三個 container 實測驗證通過；改動只有一個環境變數；
   Isaac 容器的重流量是 composable node 內的 NITROS 零拷貝，跨 process 只有極小的
   Wrench 訊息，RMW 選擇對感知效能影響有限。設定收斂在 `SAUVC-RPI/.env`，
   併入 super-repo 後上移一層由單一 `--env-file` 餵給所有堆疊。

2. **repo 命名：保留 `SAUVC-` 前綴。**

   super-repo = `SAUVC`；子 repo 為 `SAUVC-Autonomy`（原 JETSON）、`SAUVC-Control`
   （原 RPI）、`SAUVC-Simulation`、`SAUVC-STM32`。改名在建立 super-repo 時一併執行，
   本次重構仍在原 repo 內進行，不同時變動兩件事。

3. **本次新增範圍（超出原草案）。** 以下三項納入本次：

   | 項目 | 理由 |
   |---|---|
   | 深度 PID 積分抗飽和 + 輸出限幅 | 實測重現失控：載具觸底後積分項 45 秒內從 32 N 線性成長到 119 N 且無上界 |
   | 推力限幅抽成獨立節點 | 目前限幅寫在 `thruster_force_to_pwm_output_signal_node` 裡，而模擬路徑刻意跳過該節點 → 模擬完全沒有飽和行為，調出來的增益不可信 |
   | 新增 `AUTONOMOUS` 模式 | 目前沒有任何模式代表「JETSON 自主」。實測 `SAFE_DISABLED` 下 `wrench_sum` 為 inactive，decision 的 50 Hz 指令完全到不了推進器；要放行只能進 `MANUAL`（語意矛盾且會關掉深度 PID）或 `DEPTH_HOLD` |

4. **階段 5（IMU yaw PID）不納入本次。** yaw 權威來源（STM32 IMU vs 飛控 IMU）尚未決定，
   且它是唯一新增控制行為、需要實機調參的項目。獨立成後續工作。

5. **`gui` 保留範圍：待確認。** 主線必要的是手動 wrench、深度目標、推進器初始化；
   PID 即時調參 UI 建議保留（池邊調參的命脈）；`web_video_server` 的串流來源在底部
   相機退場後需重新確認。**此項會決定階段 2 的實際工作量，開工前需定案。**

6. **`fsm_decision` 與 `dive_then_forward_mission_node`。** 兩者都是被 `orca_decision`（BT）
   取代的舊實作。本計畫將後者移入 legacy；前者屬於 Autonomy repo，在該側一併加
   `COLCON_IGNORE`（見 Isaac 瘦身工作）。

---

## 8. super-repo（2026-08-03 完成）

workspace 根目錄成為 super-repo `SAUVC`，以 submodule 納入三個子系統。

| 產出 | 說明 |
|---|---|
| `.env` | **全系統環境設定的唯一來源**。三個堆疊的 ROS/DDS 參數由同一份檔案注入，不可能不一致（已驗證三個 service 的 DOMAIN / RMW / TRANSPORT / NAMESPACE 完全相同） |
| `docker-compose.yml` | control / autonomy / sim 三個 service。sim 走 profile，實機不會啟動 |
| `docker-compose.{x86,jetson,softgl}.yml` | 平台疊加檔，見下 |
| `Makefile` | `make up / build / launch / status / doctor / sim` |
| `scripts/rename_repos.sh` | repo 更名的本機端流程 |

**GPU 設定為什麼要拆成疊加檔**：`gpus: all`（x86）與 `runtime: nvidia`（Jetson）
互斥，同時給會衝突。Makefile 依 `uname -m` 自動選。`SOFTGL=1` 是**取代**平台
疊加檔而非疊在上面 —— 只要任何一個 service 還帶著 GPU 需求，在 passthrough
壞掉的機器上整個 compose 都起不來。

**`make doctor`**：把最容易靜默失敗的東西一次檢查完 —— 三個容器的 DDS 設定
是否一致、STM32 序列埠是否存在（並列出 `/dev/serial/by-id/` 可用的穩定路徑）、
GPU passthrough 是否可用、bag 磁碟空間。

### 驗證

單一 `make sim SOFTGL=1 HEADLESS=true` 拉起 Gazebo + control(sim) + autonomy，
14 個節點到齊，`wrench_sources/decision` 與 `targets/depth_m` 跨堆疊介面正確連上，
`AUTONOMOUS_AND_DEPTH_HOLD` 模式下深度定深收斂（目標 1.4 m → 1.409 m）。

### 過程中發現的環境問題（非程式碼問題）

Gazebo 在測試中途開始 segfault，症狀是「感測器 topic 完全沒有資料、supervisor
停在 FAULT / Depth sensor data has not been received」，很難聯想到是算繪問題。
真正原因是 host 的 GPU passthrough 壞掉（`nvidia-persistenced` 未執行 →
容器起不來；退回軟體算繪時 Ogre 又因為看得到 `/dev/dri` 而挑到壞掉的裝置）。

因此新增 `docker-compose.softgl.yml` 作為退路，並把 `/dev/dri` 從 base compose
移到平台疊加檔（compose 的 `devices` 是合併不是覆寫，`devices: []` 清不掉）。
`make doctor` 也加上 GPU passthrough 檢查。

---

## 9. Isaac ROS 映像（2026-08-03 完成）

### 實測的體積分佈

| 層 | 增量 | 佔比 |
|---|---|---|
| `x86_64`/`aarch64` base（Triton + CUDA devel + PyTorch + TensorRT） | 17.8 GB | 86% |
| `+ros2_humble`（含 MoveIt2 + UR + nav2 + moveit2_tutorials） | +1.7 GB | |
| `+realsense` | +0.8 GB | |
| `+orca25` | +0.3 GB | |

**肥的是 NVIDIA 的 base，不是我們裝的東西。**

### 為什麼不能靠砍 dependency 加速

`build_image_layers.sh` 用「Dockerfile 鏈的 md5」向 `nvcr.io/nvidia/isaac/ros`
查詢預先建好的映像。改動 `Dockerfile.base` / `.aarch64` / `.ros2_humble` 去砍
MoveIt / nav2 會讓 hash 對不上，Jetson 反而得從頭 build 那 17.8 GB 的 base
（含 bloom 編 MoveIt / rclcpp / image_pipeline）—— **砍 dependency 會讓 build
時間暴增而不是縮短**。

已實測驗證改最外層不影響 base 查詢：`aarch64.ros2_humble.realsense` 的
md5 = `664efa416a340be67177559a6188c01f`，在 `Dockerfile.orca25` 改動前後完全相同。

### 實際做的事

1. **`scripts/orca_registry.sh`** —— 真正能把「40 分鐘 build」變成「一次 pull」
   的做法：x86 機器 buildx 出 arm64 映像推 registry，Jetson 只 `docker pull`。
   完全不需要動任何 Dockerfile。
2. **`Dockerfile.orca25` 移除 Gazebo**（`ignition-fortress` + `ros-humble-ros-gz`）。
   實機的 Isaac 容器永遠不會跑 Gazebo，模擬有自己的容器。該層 1.1 GB → 0.3 GB。
3. **`sauvc_sim` 與 `fsm_decision` 移入 `legacy/`** 並加 `COLCON_IGNORE`，
   不再參與每一次 colcon build。
4. **移除 `realsense-ros` submodule**（與 `Dockerfile.realsense` 裝進映像的
   NVIDIA fork 重複，且從未初始化）與 **`Dockerfile.orca`**（已被 orca25 取代）。

### 未處理

`model/` 底下 5 個 `.onnx` 共 214 MB 直接 commit 進 repo（`.git` 已 310 MB），
其中 `best_conti.onnx` 與 `best_pretrain.onnx` 共 86 MB 沒有被任何 config 引用。
單純刪除不會讓 clone 變小（歷史仍在），需要改寫 git 歷史或改用 Git LFS /
Release artifact，屬於獨立的一次性作業。

---

## 10. 尚未完成

| 項目 | 狀態 |
|---|---|
| repo 更名（`SAUVC-Control` / `SAUVC-Autonomy`） | 本機端流程已腳本化（`scripts/rename_repos.sh`），**GitHub 端的改名必須由有權限的人手動執行**，腳本會先檢查新名稱是否存在才動作 |
| IMU yaw-hold PID | 需先決定 yaw 權威來源（STM32 IMU vs 飛控 IMU），見 §3.6 第 5 點 |
| 跨 repo 介面落差 | §3.6 列的六項（單位落差、heave 無增益、機械臂通道斷開、無回饋、雙 IMU、namespace 硬編碼）都還在，全部屬於 Autonomy 側 |
| `.onnx` 進 Git LFS | 見 §9 |
