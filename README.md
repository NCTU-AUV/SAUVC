# SAUVC —— Orca AUV

NCTU-AUV 參加 SAUVC（Singapore AUV Challenge）的水下自主載具。
這是 **super-repo**：以 submodule 納入所有子系統，提供一次部署、一次啟動的入口。

```text
                    ┌─────────────────── Jetson Orin NX ───────────────────┐
                    │                                                       │
  RealSense ───────►│  ┌─ container: autonomy ─┐   ┌─ container: control ─┐ │
  底部 USB 相機 ────►│  │ YOLOv8 (TensorRT)     │   │ 深度 PID             │ │
                    │  │        ↓              │   │ wrench 匯流排        │ │
                    │  │ depth_perception      │   │ 推力分配 + 飽和限幅  │ │
                    │  │        ↓              │   │        ↓             │ │
                    │  │ BehaviorTree 決策     │──►│  力 → PWM            │ │
                    │  └───────────────────────┘   └──────────┬───────────┘ │
                    │        wrench_sources/decision          │             │
                    │        targets/depth_m                  │             │
                    └─────────────────────────────────────────┼─────────────┘
                                                              │ USB
                                                         ┌────▼────┐
                                                         │  STM32  │ 壓力/IMU/推進器
                                                         └─────────┘
```

| Submodule | 職責 |
|---|---|
| [SAUVC-RPI](SAUVC-RPI/) | 控制：PID、wrench 匯流排、推力分配、系統模式與安全、Web GUI |
| [SAUVC-JETSON](SAUVC-JETSON/) | 感知與決策：YOLOv8 + 深度估計 + BehaviorTree |
| [SAUVC-Simulation](SAUVC-Simulation/) | Gazebo Fortress 場景與 ROS 橋接 |
| SAUVC-STM32 | 韌體（在 SAUVC-RPI 底下） |

> 名稱已不精確：`SAUVC-RPI` 裡沒有樹莓派，兩套堆疊都跑在同一塊 Orin NX 的兩個容器裡。
> 預計更名為 `SAUVC-Control` / `SAUVC-Autonomy`，見 [scripts/rename_repos.sh](scripts/rename_repos.sh)。

---

## 安裝

```shell
git clone --recurse-submodules https://github.com/NCTU-AUV/SAUVC.git
cd SAUVC
```

已 clone 過：`make submodules`

control 與 sim 的映像由 compose 建置；autonomy 的 Isaac 映像不是，**不要在 Jetson 上 build**：

```shell
make build_images          # control + sim
make pull_autonomy         # autonomy（從 registry 拉）
```

要自己建 Isaac 映像的流程見 [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)。

---

## 開始

### 實機

```shell
make up        # 啟動容器
make build     # colcon build 兩個 workspace
make launch    # 啟動 ROS 節點
make status    # 檢查
```

### 模擬

```shell
make up && make build
make sim ARENA=finals SEED=2
```

`make sim` 會一路跑完 Gazebo → 就緒檢查 → control(sim) → autonomy → 就緒檢查 → status。
**首次會在感知就緒那步等好幾分鐘**，TensorRT 要建 CUDA engine，這是正常的。

`make build` 不能省 —— install space 是 named volume，沒 build 過的新檔案不在裡面。

---

## 使用

### 讓載具動起來

開機預設 `SAFE_DISABLED`，推進器沒有輸出。先 arm（服務型別是 `Trigger` 不是 `SetBool`）：

```shell
docker compose exec control bash -lc 'source /opt/ros/humble/setup.bash && source /root/rpi_ros2_ws/install/setup.bash && ros2 service call /orca_auv/system_manager/set_mode/depth_hold std_srvs/srv/Trigger && ros2 service call /orca_auv/system_manager/set_mode/autonomous std_srvs/srv/Trigger'
```

再啟動任務：

```shell
docker compose exec autonomy bash -lc 'source /opt/ros/humble/setup.bash && source /workspaces/isaac_ros-dev/install/setup.bash && ros2 topic pub --once /orca/decision/start_mission std_msgs/msg/Bool "{data: true}"'
```

| 模式服務 | 作用 |
|---|---|
| `set_mode/depth_hold` | 深度保持 |
| `set_mode/autonomous` | 放行 `wrench_sources/decision`，可與 depth_hold 疊加 |
| `set_mode/safe_disabled` | 全部停用，也是清除 FAULT 的方式 |

kill switch、深度感測器逾時、decision wrench 逾時都會進 `FAULT` 並停掉輸出。
FAULT 中的啟用請求會被回絕（`success=False`），要先 `safe_disabled`。

### 查看狀態

| 指令 | 用途 |
|---|---|
| `make status` | 容器 / 節點 / 模式 / 跨堆疊介面 / 感知鏈 |
| `make doctor` | 部署前自檢：DDS 一致性、序列埠、X11、GPU |
| `make logs_control` | control 的 launch log |
| `make logs_autonomy` | autonomy 的 launch log |
| `make logs_sim` | Gazebo 的 launch log |

行為樹走到哪：

```shell
docker compose exec autonomy bash -lc 'source /opt/ros/humble/setup.bash && source /workspaces/isaac_ros-dev/install/setup.bash && ros2 topic echo /orca/decision/status'
```

### 停止

```shell
make stop      # 停掉 ROS 節點，容器留著
make down      # 停掉容器
```

### 可調參數

| 變數 | 預設 | 說明 |
|---|---|---|
| `SIM` | `false` | control 跑模擬模式；同時決定 autonomy 用哪份感知設定 |
| `ARENA` | `finals` | `finals` / `qualification` |
| `SEED` | 隨機 | 固定場地佈局。**`SEED=2` 是目前驗證過能過閘門的** |
| `HEADLESS` | `false` | 不開 Gazebo GUI |
| `SOFTGL` | — | `SOFTGL=1` 用軟體算繪，GPU passthrough 壞掉時 |
| `VIZ` | 用 YAML 值 | `VIZ=true` 開感知視覺化（需要 X server） |
| `DRUM_STYLE` | `random` | `drum` / `tub` / `random` |
| `RANDOMIZE_WATER` | `false` | 水質與能見度隨時間變化 |
| `PERCEPTION` | `true` | `false` 只跑行為樹（世界模型會是空的） |

---

## 設定

**所有環境設定的唯一來源是 [`.env`](.env)。** 子 repo 各自的 `.env` 只在單獨開發該堆疊時生效。

| 位置 | 內容 |
|---|---|
| [`.env`](.env) | namespace、DDS、裝置路徑、DISPLAY |
| [SAUVC-RPI/.../orca_bringup/config/](SAUVC-RPI/rpi_ros2_ws/src/orca_bringup/config/) | PID 增益、推進器幾何、bag 錄製 |
| [SAUVC-JETSON/.../orca_perception/config/](SAUVC-JETSON/perception_pipeline/orca_perception/config/) | 感知管線（實機 / 模擬兩份） |
| [SAUVC-JETSON/orca_decision/config/](SAUVC-JETSON/orca_decision/config/) | 行為樹與決策參數 |

---

## Bag 錄製

隨啟動自動開始，落在 host 的 `bags/`，格式 mcap、每 120 秒切一段。
錄什麼由 [record_topics.yaml](SAUVC-RPI/rpi_ros2_ws/src/orca_bringup/config/record_topics.yaml) 決定
（感測輸入 → 目標 → PID → wrench 匯流排 → 推力分配 → 推進器指令；影像預設不錄）。

載具是靠 kill switch 直接斷電的，所以 bag 目錄通常沒有 `metadata.yaml`，
`ros2 bag info` 會打不開。**資料沒有遺失**，撈之前先：

```shell
ros2 bag reindex <bag_dir> -s mcap
```

---

## 文件

| 文件 | 內容 |
|---|---|
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | 容器與映像佈局、DDS、compose 疊加檔、X11 |
| [docs/HANDOFF.md](docs/HANDOFF.md) | 交接：座標慣例、已知缺陷、驗收方式、踩過的坑 |
| [docs/SIM_VISUAL_FIDELITY.md](docs/SIM_VISUAL_FIDELITY.md) | 場景依 2026 rulebook 改造、水下成像模型、量化驗證 |
| [docs/SIMULATION_FINDINGS.md](docs/SIMULATION_FINDINGS.md) | 三容器全鏈路實測報告 |
| [docs/REFACTOR_PLAN.md](docs/REFACTOR_PLAN.md) | 重構計畫與決策紀錄 |
| [SAUVC-RPI/docs/ARCHITECTURE.md](SAUVC-RPI/docs/ARCHITECTURE.md) | 控制堆疊架構 |
| [SAUVC-JETSON/ARCHITECTURE.md](SAUVC-JETSON/ARCHITECTURE.md) | 感知決策堆疊架構 |
