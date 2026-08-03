# SAUVC —— Orca AUV

NCTU-AUV 參加 SAUVC（Singapore AUV Challenge）的水下自主載具。
這是 **super-repo**：以 submodule 納入所有子系統，並提供一次部署、一次啟動的入口。

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

## 子系統

| Submodule | 職責 |
|---|---|
| [SAUVC-RPI](SAUVC-RPI/) | **載具控制堆疊**：PID、wrench 匯流排、推力分配、系統模式與安全、Web GUI |
| [SAUVC-JETSON](SAUVC-JETSON/) | **感知與決策堆疊**：YOLOv8 + 深度估計 + BehaviorTree 任務執行 |
| [SAUVC-Simulation](SAUVC-Simulation/) | Gazebo Fortress 場景與 ROS 橋接 |
| SAUVC-STM32 | 韌體（在 SAUVC-RPI 底下） |

> **關於名稱**：`SAUVC-RPI` 裡已經沒有樹莓派，`SAUVC-JETSON` 也不是「只有 Jetson
> 才跑的東西」—— 兩套堆疊現在都跑在同一塊 Orin NX 上的兩個容器裡。
> 預計更名為 `SAUVC-Control` 與 `SAUVC-Autonomy`，流程見
> [scripts/rename_repos.sh](scripts/rename_repos.sh)（GitHub 端要先手動改名）。

**為什麼維持兩個容器而不合併**：base image 無法調和（CUDA devel + Isaac ROS
全家桶 vs 乾淨的 `ros:humble`）；改動頻率差距極大（控制堆疊天天調參，Isaac
映像半年不動）；故障隔離（感知 OOM / GPU 異常不該拖垮推進器控制）。

## 取得

```shell
git clone --recurse-submodules https://github.com/NCTU-AUV/SAUVC.git
cd SAUVC
```

已經 clone 過的話：`make submodules`

## 快速開始

```shell
make up        # 啟動 control + autonomy 容器
make build     # 兩個 workspace 都 colcon build
make launch    # 啟動兩個堆疊的 ROS 節點
make status    # 節點 / 模式 / 跨堆疊介面一覽
```

Isaac ROS 映像不由 compose 建置（它是 `build_image_layers.sh` 分層組出來的）。
**不要在 Jetson 上 build**——用 x86 機器建好推 registry：

```shell
# 開發機
SAUVC-JETSON/isaac_ros_common/scripts/orca_registry.sh build --arm64
SAUVC-JETSON/isaac_ros_common/scripts/orca_registry.sh push

# Jetson
make pull_autonomy
```

### 模擬

```shell
make sim                 # Gazebo + control(sim) + autonomy，一次到位
make sim SOFTGL=1        # 這台機器的 GPU passthrough 壞掉時
make sim HEADLESS=true   # 不開 Gazebo GUI（沒有 X11 的環境用這個）
```

`make sim` 會自己把三個容器都拉起來，並在 GUI 模式下自動下
`xhost +local:root` 讓容器連得上 X server。少了那道授權，Gazebo 的 Qt 會以
`Authorization required` 失敗然後整個程序死掉，表現出來卻只是「感測器 topic
沒有資料」。

### 出問題先跑這個

```shell
make doctor
```

檢查最容易靜默失敗的幾件事：三個容器的 DDS 設定是否一致、STM32 序列埠是否存在、
GPU passthrough 是否可用、bag 磁碟空間夠不夠。

## 設定

**所有環境設定的唯一來源是 [`.env`](.env)。** 三個堆疊的 ROS/DDS 參數都由它注入，
不可能不一致。子 repo 各自也有一份 `.env`，那是單獨開發該堆疊時的 fallback；
從 super-repo 啟動時不會生效。

控制參數（PID 增益、推進器幾何等）在
[SAUVC-RPI/rpi_ros2_ws/src/orca_bringup/config/](SAUVC-RPI/rpi_ros2_ws/src/orca_bringup/config/)。

### DDS 設定為什麼要統一

`FASTDDS_BUILTIN_TRANSPORTS=UDPv4` 是**正確性設定，不是效能調校**。

control 容器掛載了 host 的 `/dev`（要存取 STM32 序列埠），連帶把 `/dev/shm` 也
換成 host 的；autonomy 與 sim 容器則各自有獨立的 `/dev/shm`。Fast DDS 預設會
宣告共享記憶體 locator，此時跨容器的 participant 會互相 match 到、資料卻永遠
走不通，**而且不會有任何錯誤訊息** —— 表現出來就是「載具不動」。

實測：未設定時，容器內 `ros2 node list` 連自己啟動的節點都看不到；設定後三個
容器 19 個節點一次到齊。

### compose 檔案怎麼分

| 檔案 | 用途 |
|---|---|
| `docker-compose.yml` | 三個 service 的共同定義，不含任何硬體相依 |
| `docker-compose.x86.yml` | x86 開發機：`gpus: all` + `/dev/dri` |
| `docker-compose.jetson.yml` | Jetson：`runtime: nvidia` + tegra / VPI 掛載 |
| `docker-compose.softgl.yml` | 沒有可用 GPU passthrough 時的軟體算繪退路 |

GPU 的給法在兩個平台上互斥（`gpus: all` vs `runtime: nvidia`），所以拆成疊加檔，
Makefile 依 `uname -m` 自動選。`SOFTGL=1` 是**取代**平台疊加檔而不是疊在上面——
只要任何一個 service 還帶著 GPU 需求，在 passthrough 壞掉的機器上整個 compose
都會起不來。

## 控制模式

由 control 堆疊的 `supervisor_node` 集中管理：

```shell
ros2 service call /orca_auv/system_manager/set_mode/depth_hold    std_srvs/srv/Trigger {}
ros2 service call /orca_auv/system_manager/set_mode/autonomous    std_srvs/srv/Trigger {}
ros2 service call /orca_auv/system_manager/set_mode/safe_disabled std_srvs/srv/Trigger {}
```

`autonomous` 放行 Autonomy 堆疊的 `wrench_sources/decision`，可與 `depth_hold`
疊加。任一安全前提被打破（kill switch、深度感測器逾時、decision wrench 逾時）
都會立刻進 `FAULT` 並停掉所有輸出。

## Bag 錄製

隨啟動自動開始錄（比賽時沒有人會記得按錄影），落在 host 的 `bags/`。

> AUV 是靠 kill switch 直接斷電關機的，所以 bag 目錄通常不會有 `metadata.yaml`，
> `ros2 bag info` 會打不開。**這是正常的，資料沒有遺失。** 撈資料前先跑：
>
> ```shell
> ros2 bag reindex <bag_dir> -s mcap
> ```

## 文件

- [docs/REFACTOR_PLAN.md](docs/REFACTOR_PLAN.md) —— 重構計畫、決策紀錄與執行結果
- [docs/SIMULATION_FINDINGS.md](docs/SIMULATION_FINDINGS.md) —— 三容器全鏈路實測報告
- [SAUVC-RPI/docs/ARCHITECTURE.md](SAUVC-RPI/docs/ARCHITECTURE.md) —— 控制堆疊架構
- [SAUVC-JETSON/ARCHITECTURE.md](SAUVC-JETSON/ARCHITECTURE.md) —— 感知決策堆疊架構
