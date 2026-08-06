# 部署與容器佈局

從 [README](../README.md) 移出來的說明。這裡放的是「為什麼這樣配」——
會靜默失敗、且症狀完全不指向原因的那幾件事。

---

## 為什麼是兩個容器而不是一個

- **base image 無法調和**：CUDA devel + Isaac ROS 全家桶 vs 乾淨的 `ros:humble`。
- **改動頻率差距極大**：控制堆疊天天調參，Isaac 映像半年不動。
- **故障隔離**：感知 OOM 或 GPU 異常不該拖垮推進器控制。

---

## 映像怎麼來

| 容器 | 來源 |
|---|---|
| control | compose 建置（`make build_images`） |
| sim | compose 建置（`make build_images`） |
| autonomy | Isaac ROS，由 `build_image_layers.sh` 分層組出，**不由 compose 建置** |

Isaac 映像不要在 Jetson 上 build ——用 x86 機器建好推 registry：

```shell
# 開發機
SAUVC-JETSON/isaac_ros_common/scripts/orca_registry.sh build --arm64
SAUVC-JETSON/isaac_ros_common/scripts/orca_registry.sh push

# Jetson
make pull_autonomy
```

---

## DDS 設定為什麼要統一

`FASTDDS_BUILTIN_TRANSPORTS=UDPv4` 是**正確性設定，不是效能調校**。

control 容器掛載了 host 的 `/dev`（要存取 STM32 序列埠），連帶把 `/dev/shm` 也換成
host 的；autonomy 與 sim 容器則各自有獨立的 `/dev/shm`。Fast DDS 預設會宣告共享
記憶體 locator，此時跨容器的 participant 會互相 match 到、資料卻永遠走不通，
**而且不會有任何錯誤訊息** —— 表現出來就是「載具不動」。

實測：未設定時，容器內 `ros2 node list` 連自己啟動的節點都看不到；設定後三個容器
19 個節點一次到齊。

---

## compose 檔案怎麼分

| 檔案 | 用途 |
|---|---|
| `docker-compose.yml` | 三個 service 的共同定義，不含任何硬體相依 |
| `docker-compose.x86.yml` | x86 開發機：`gpus: all` + `/dev/dri` |
| `docker-compose.jetson.yml` | Jetson：`runtime: nvidia` + tegra / VPI 掛載 |
| `docker-compose.softgl.yml` | 沒有可用 GPU passthrough 時的軟體算繪退路 |

GPU 的給法在兩個平台上互斥（`gpus: all` vs `runtime: nvidia`），所以拆成疊加檔，
Makefile 依 `uname -m` 自動選。

`SOFTGL=1` 是**取代**平台疊加檔而不是疊在上面 —— 只要任何一個 service 還帶著 GPU
需求，在 passthrough 壞掉的機器上整個 compose 都會起不來。

---

## X11 授權

`make sim` 在 GUI 模式下會自動下 `xhost +local:root`。少了那道授權，Gazebo 的 Qt 會以
`Authorization required` 失敗然後整個程序死掉，表現出來卻只是「感測器 topic 沒有資料」。

`HEADLESS=true` 時不需要，也不會下。

---

## install space 是 named volume

三個 workspace 的 `build/` `install/` `log/` 都是 named volume，映像裡沒有預先 build 過。
所以：

- 主機上 build 過也會被 volume 蓋掉。
- **任何新增的檔案在 `make build` 之前不存在於 install space。**
  `install(DIRECTORY ...)` 在 `--symlink-install` 底下產生的是逐檔符號連結，不是整個目錄。

`make launch_autonomy` 有 `autonomy_installed` 前置會擋下這種情況並要你去 build；
`sim_launch` 則直接自動跑 `build_sim`。
