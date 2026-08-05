# 交接文件

寫給下一個接手這個專案的人（或 coding agent）。內容是 2026-08-04/05 這一輪
「重構後全專案審查 + 修正」留下的狀態、驗證方法與踩過的坑。

讀完這份之後最該先看的兩份是 `docs/SIMULATION_FINDINGS.md`（更早一輪的模擬
問題紀錄）與 `SAUVC-RPI/docs/ARCHITECTURE.md`（控制堆疊架構）。

---

## 0. 現在的狀態（最重要）

**四個 PR 開著，還沒合併。合併順序不能反。**

| 順序 | PR | 內容 |
|---|---|---|
| 1 | [SAUVC-JETSON#5](https://github.com/NCTU-AUV/SAUVC-JETSON/pull/5) | 感知管線接進啟動流程、IMU 話題與重力座標、gate 深度與接近邏輯 |
| 1 | [SAUVC-RPI#116](https://github.com/NCTU-AUV/SAUVC-RPI/pull/116) | 模式請求回絕、FAULT 鎖存、深度力箝制 |
| 1 | [SAUVC-Simulation#25](https://github.com/NCTU-AUV/SAUVC-Simulation/pull/25) | IMU 安裝姿態、資料集標註四項、資格賽 profile |
| 2 | [SAUVC#2](https://github.com/NCTU-AUV/SAUVC/pull/2) | Makefile 三項 + 三個子模組指標 |

三個子模組 PR 必須全部合併之後，超級倉的 PR 才能合 —— 否則 main 上的子模組
指標會指向還沒進 main 的 commit，任何人 clone 都會拿到壞掉的 checkout。

**必須用 merge commit，不要 squash。** 超級倉記錄的子模組 SHA 是各子模組 PR
分支上的 commit；squash 會讓那些 commit 不可達，指標就變成孤兒。

四個 repo 的 `main` 都有分支保護（`GH013: Changes must be made through a pull
request.`），任何直接 push 到 main 都會被拒絕，不要浪費時間試。

### 本地 git 環境

- JETSON 與 RPI 的 remote fetch URL 是 https，非互動環境無法認證。已用
  `git remote set-url --push origin git@github.com:...` 補上 SSH push URL
  （fetch URL 未動）。Simulation 本來就是這個設定。
- 這台機器的 SSH 金鑰對應 GitHub 帳號 `gethation`。
- 四個 repo 目前都在各自的新分支上，工作區乾淨。

---

## 1. 系統速覽

三個子模組 + 一個整合層，全部跑在 Docker 容器裡，由超級倉的 `Makefile` 驅動。

```text
SAUVC-JETSON     自主：YOLOv8(TensorRT) 感知管線 + BehaviorTree 決策
SAUVC-RPI        控制：深度 PID、wrench 匯流排、推力分配、系統狀態機、Web GUI
SAUVC-Simulation 模擬：Gazebo Fortress 世界、水下相機渲染、場地生成、資料集產生
SAUVC (超級倉)    整合：Makefile、docker-compose、跨堆疊設定
```

資料流（模擬情境）：

```text
Gazebo ──sensors/imu 100Hz──────────────────────────► decision_node（世界模型）
       ──color/image_raw_dry──► underwater_camera ──► camera_selector ──► DNN encoder
                                                                            │
                                                                     TensorRT(finals.onnx)
                                                                            │
                                                                     yolov8_decoder
                                                                            │
                                          depth_perception ◄── /detections_output
                                                     │
                                          /orca/perception_array ──► decision_node
                                                                            │
                                                             BehaviorTree(trees.xml)
                                                                            │
                                                                     wrench_adapter
                                                                            │
                    control/wrench_sources/decision ──► wrench_sum ──► 推力分配 ──► Gazebo
```

容器名稱：`orca-control`、`orca-autonomy`、`orca-sim`。

---

## 2. 必讀：實測確認的座標慣例

**這一節是整份文件最容易讓人做錯事的地方。** 稽核報告曾經因為套用 REP-103
（z 向上、CCW 為正）而得出錯誤結論，差點把正確的程式改壞。

整個堆疊採用**往下為正**的機體座標（FRD 風格）：

| 量 | 慣例 | 實測驗證方式 |
|---|---|---|
| `force.z` 正值 | **下沉** | 給 +Fz 10 N，Gazebo 的 z 下降 0.249 m |
| `force.x` 正值 | **前進** | 給 +Fx 20 N，載具由 x=-11.75 移到 -9.45 |
| `torque.z` 正值 | **右轉（starboard）** | 見下方「角度繞回」的警告 |
| IMU `linear_acceleration.z` 靜止時 | **-9.81** | 加速度計量的是比力 `f = a - g`，g = (0,0,+9.81) |
| IMU 回報的 yaw | 與 Gazebo 世界 yaw **反號** | IMU 的 z 朝下 |
| 偵測座標 `cx`/`cy` | **640×640 張量空間**，中心 (320, 320) | 不是 640×480，中心不是 (320,240) |

控制端對「往下為正」的權威來源是
`SAUVC-RPI/rpi_ros2_ws/src/depth_control/depth_control/output_sink_force_to_output_wrench_node.py`
的 `world_frame_sink_direction`，其向量部是 `(0, 0, 1)`。

### 陷阱：角度繞回會騙過單點量測

判斷 `+torque.z` 的轉向時，我第一次用「施力前讀一次 yaw、施力後讀一次」，
得到的答案是**左轉**，與幾何計算矛盾。原因是 yaw 在 ±π 繞回，單點差值無法
區分「+2.18 rad」與「-4.10 rad」。

改成在施力期間以 4 Hz 連續取樣、用 `np.unwrap` 解繞之後，答案是**右轉**，
與從 SDF 推進器幾何解析計算的結果一致（兩個獨立方法互相印證）。

**任何要判斷轉向的實驗，都必須連續取樣並解繞。**

### 重新驗證這些慣例的腳本

當時用的三個一次性腳本沒有進 repo（它們依賴 `ign model -m orca_auv -p` 與
直接發布 `/orca_auv/thrusters/thruster_N/force_N`）。要重做的話，關鍵作法是：

1. 用 `hardware.yaml` 的 `thruster_positions_m` / `thruster_directions` 建
   分配矩陣（`np.linalg.pinv` 於 `[force_rows; torque_rows]`），算出對應某個
   目標 wrench 的八顆推進器出力。
2. 繞過 supervisor，直接發布到八個 `thrusters/thruster_N/force_N`。
3. 用 `ign model -m orca_auv -p` 讀真實位姿（會印出 XYZ 與 RPY 兩行）。

---

## 3. 已修正的項目（16 項 + 2 項額外發現）

以下都已在模擬中驗收，散布在四個 PR 裡。

### 整合層（超級倉）
1. **感知管線從來沒有被啟動** —— `launch_autonomy` 只跑 `decision.launch.py`，
   而後者只有 `decision_node`。沒有任何節點發布 `/orca/perception_array`，
   行為樹全程盲跑而 `make status` 顯示健康。改用新的 `autonomy.launch.py`。
2. **`make sim` 其實沒有啟動 Gazebo** —— `sim_ws` 的 build/install 是 named
   volume 且映像裡沒預先 build 過，`source install/setup.bash` 失敗導致整串
   `&&` 中斷；`exec -T -d` 又丟掉離開碼。新增 `build_sim` 與 `sim_check`。
3. **模擬設定檔沒有任何東西會選到它** —— `sim_launch` 現在會帶
   `PERCEPTION_CONFIG=simulation_params.yaml`。
4. **停止模擬留下孤兒程序** —— 新增 `STOP_SIM`（見第 7 節）。

### 自主（JETSON）
5. **IMU 話題沒有發布者** —— `decision_node` 訂閱 `/orca/imu/data`，但全專案
   只有 `<ns>/sensors/imu`。世界模型的姿態永遠停在單位四元數。
6. **重力符號** —— 往下為正時移除重力是「加」不是「減」。修正前任務 20 秒後
   `target_position.z` 是 **-253 m**（池深 1.6 m），修正後 -0.0013 m。
7. **`mode_topic` 預設值過期** —— `/orca/camera_mode` → `/orca/decision/camera_mode`。
8. **gate 深度估測在遠距離必定失敗** —— `gate_col_min_points: 30` 是絕對像素
   數，但一欄最多只有 bbox 高度那麼多像素；遠處 gate 只有 22 px 高，沒有任何
   一欄能通過，距離永遠 `-1.0`。左右柱切片的固定 `15` 也會在欄數 ≤15 時取到
   同一份資料。
9. **`ApproachTarget` 距離為負時全速前衝** —— 「深度未解出」與「已經太近」被
   摺成同一個 `dist_error = 1000` → 最大 surge。
10. **影像中心寫死 240** —— 應為 320。

### 控制（RPI）
11. **arming 前提不滿足會讓整車 FAULT** —— 在水中保持深度時勾選自主，若
    Jetson 還沒發出第一筆 wrench，深度保持當場消失。改成回絕請求。
12. **FAULT 沒有真的鎖存** —— 任一 disable 鍵會清掉 FAULT 與故障原因。
13. **深度偏壓加在箝位之後** —— `force.z` 到 70 N，四顆垂直推進器各 17.5 N
    超限，`scale` 把八顆一起縮 14%。新增 `max_sink_force_N`。

### 模擬（Simulation）
14. **IMU 安裝姿態用錯旋轉軸** —— 用 pitch 180° 會同時翻轉 x；正確是 roll 180°。
15. **資格賽場地無法產生資料集** —— 新增 `--profile finals|qualification`。
16. **四項資料集標註缺陷** —— `occluded()` 自遮蔽、`contrast()` 滿版回傳 0、
    方形箱套用圓桶尺寸、`orange_flare` 標註框三倍寬。

### 額外發現（不在原稽核清單上）
- `sim_check` 的就緒判斷改了三次才對（見第 7 節）。
- 停止模擬會留下 `parameter_bridge` 孤兒，導致重跑後感測器有兩個發布者、
  頻率翻倍而數值看起來正常。

---

## 4. 一項被推翻的稽核結論（不要「修」它）

稽核報告列出「視覺伺服 yaw 符號相反」（`approach_target.cpp` 與
`final_align_target.cpp` 的 `cmd.yaw = -0.005f * error_x`）。

**這是誤判，程式是對的，已確認並保留原樣。**

報告是套用 REP-103（z 向上、CCW 為正）推論的。實際上本堆疊是往下為正，
`+torque.z` 是右轉；目標在畫面右側時 `error_x = 320 - cx < 0`，`cmd.yaw > 0`，
正是右轉 —— 朝向目標。`TurnToYaw` 與 `BlindForward` 的 `cmd.yaw = +error`
同理也正確。

四個節點彼此一致，也與模擬實測一致。相關的推導與量測寫在
`approach_target.cpp` 的註解裡。

---

## 5. 剩下的缺陷（24 項）

原始稽核清單共 41 項，已修 16、推翻 1（上一節）、部分修 1。以下是剩下的，
依「修了會解鎖什麼」分組。編號沿用原清單。

### A. 阻擋第二階段任務（投球到藍桶）

行為樹的 `TargetAcquisition` 是
`SearchTarget → ApproachTarget → FinalAlignTarget → 切底部相機 → MoveAboveTarget → DropBall → CheckBottomClear`。
模擬**有**底部相機（`bottom_camera` sensor 已橋接到 `camera/bottom/image_raw`），
所以這段是可測的。

- **(9, 部分未修)** `SAUVC-JETSON/orca_decision/config/decision_params.yaml`
  的 `bottom_cam_center_y: 240.0` 應為 `320.0`。我只修了兩個 BT 節點裡寫死的
  值，這個參數還沒動，`MoveAboveTarget` 仍有永久 80 px 偏差、永遠無法置中
  （門檻是 20 px），150 秒逾時後 Task 2 失敗。**這是第一個阻塞點。**
- **致動通道完全沒接** `/orca/decision/arm` 與 `/orca/decision/hand` 在三個
  堆疊裡都沒有訂閱者；RPI 的致動話題是 `actuators/electromagnet/enabled`，
  且只接到 Web GUI。`ExtendArm`/`GrabBall`/`RetractArm`/`DropBall` 全都是空
  操作，等 1 秒後回報 SUCCESS。
- **`DropBall` 與 `GrabBall` 發相同的值** 兩者都發 `hand.data = false`，而
  `DropBall` 的註解寫的是 `true`。至多只有一個是對的。
- **(13)** `yolov8_decoder_node.cpp` 傳給 `cv::dnn::NMSBoxes` 的第 6 個參數
  `5` 是 `eta`（自適應門檻倍率）不是 `top_k`。門檻每保留一個框就乘 5，很快
  超過 1.0，NMS 等於失效，每個物件產生多個重複框。

### B. 阻擋第三階段任務

- **(7)** `trees.xml` 的 `label="ball"` 不在 7 類模型裡（沒有 ball 這一類）。
  Task 3 無法成功，`FinalMission` 永遠走不到 `FinishMission`。
- **(8)** `drop_pose` 由 `DropBall` 寫入 `TargetAcquisition` 子樹的黑板，卻由
  `TargetReacquisition` 子樹的 `GoToPose` 讀取。BT.CPP v3 的子樹黑板是隔離的，
  `trees.xml` 沒有 remap 也沒有 `__shared_blackboard`，查找必定失敗。

### C. 模擬保真度與效能

- **(21)** 水下渲染每張 24.1 ms（30 Hz 只有 33.3 ms 預算），其中雜訊產生佔
  8.3 ms，且 `np.random.normal` 回傳 float64 使整張影像升格。best-effort QoS
  讓多餘影格靜默丟棄：原始 30 Hz、處理後只剩 8–12 Hz。**實測目前約 5–7 Hz。**
- **(22)** `max_range_m = 60.0` 與相機的 `<far>20</far>` 矛盾，超出裁切的幾何
  回傳 inf 被映射到 60 m，透射率在單一像素邊界出現 7 倍階躍 —— 畫面上一條
  真實水下影像不會有的直線接縫。
- **(23)** 深度影像沒有時效檢查。啟動時前幾張用 60 m 填滿，深度串流停掉會
  無限期套用凍結的深度圖。
- **(24)** `water_surface` 不透明盒（z ∈ [-0.03, -0.01]）把生成在 z=0.02 的
  起始區與資格賽起始線整個蓋住，水下視角看不到。
- **(25)** 非整數 `SEED`（例如 `make sim SEED=run42`）讓 spawner 在建構子裡
  崩潰，Gazebo 起來是空池而 `make status` 仍顯示健康。
- **(26)** whitelist 接受 `bgr8` 但按 RGB 順序套衰減係數，會反轉「紅桶變黑」
  這個線索。目前 Gazebo 送 rgb8 所以是潛伏的。

### D. 改了沒有作用的設定

- **(27)** `ORCA_STM32_PORT` 沒有列在 `SAUVC-RPI/docker-compose.yml` 的
  `environment:`，容器內永遠讀不到，一律退回 `/dev/ttyUSB0`。
- **(28)** 模擬的 `namespace:=` 被 `model.sdf` 裡寫死的 `orca_auv` 架空（5 處
  感測器 + 8 個推進器）。改 `ORCA_NAMESPACE` 會讓所有感測器斷線且不報錯。
- **(29)** 任務模式有兩個必須手動同步的真相來源：`perception_params.yaml` 的
  `model_profile` 與 `decision_params.yaml` 的 `main_tree_id`。
- **(30)** `use_sim_time` 在任何地方都沒設定。世界模型用感測器時戳算 dt，但
  清除過期物件用牆鐘；實時倍率 < 1 時世界模型會被清空。
- **(31)** `docker-compose.softgl.yml` 沒有清掉 base 檔的 `NVIDIA_VISIBLE_DEVICES`
  （compose 合併 map 無法 unset），在以 nvidia 為預設 runtime 的主機上
  `SOFTGL=1` 仍會 segfault。
- **(32)** `.env` 的 `XAUTH_FILE` 零引用；`XAUTHORITY` 指向從未掛載的檔案；
  `xhost_grant` 只是 `sim_launch` 的前置條件，`make up`+`make launch` 路徑的
  所有 X11 視窗都開不起來。
- **(33)** 儀表板的 autonomous 勾選框不跟隨 `system_manager/mode` 更新，進
  FAULT 後重新啟用需要點兩次，第一次還會回報成功。
- **(34)** `controller.js` 的 `window.ORCA_CAMERA_TOPIC` 全專案沒有任何地方
  賦值，「相機來源可設定」未實作。

### E. 殘留與未完成

- **(35)** `wrench_adapter.cpp` 沒有 `k_heave_` 增益，第一個設定 heave 的 BT
  節點會在共用匯流排上與深度 PID 對抗。
- **(36)** `bump_flare.cpp` 從輸入埠讀進 `timeout` 後又被參數無條件覆寫，
  `trees.xml` 上的 `timeout="15.0"` 是死設定。
- **(37)** `depth_perception_node.py` 的穩定性判定三個 deque 沒有時間對齊
  （命中每幀記錄，位置與信心值只在有偵測時記錄）。
- **(38)** `SAUVC-RPI/Makefile:298` 呼叫已被刪除的 `wrench_sum.launch.py`。
- **(39)** `record_topics.yaml` 仍記錄已移入 legacy 的 optical-flow 話題，配合
  `--include-unpublished-topics` 會讓每個 bag 多出永久空白項目。

### F. 設計層面（不是一行能修的）

- **(41)** `WorldModel::position_` 是純 IMU 的開迴路二次積分，沒有任何絕對
  位置參考，長時間必然漂移。`GoToPose` 與 `drop_pose` 都依賴它。要真的可用
  需要引入深度計 + 視覺的位置修正。
- **搜尋策略只會原地旋轉** `SearchTarget` 用固定力矩掃描，目標若在偵測距離
  之外就永遠找不到，而且在 `PassGateProcedure` 與 `TargetAcquisition` 裡沒有
  `Timeout` 包裹，會無限期空轉。

### 建議順序

1. **A 組** —— 直接延續現在能跑的模擬，驗收方式與過 gate 相同。
2. **B 組** —— 讓 `FinalMission` 能走完。
3. **D 組的 (27)/(30)** —— 下水前會咬人。
4. **C 組** —— 要重新訓練模擬用模型時再說（先修 (24) 與 (25)）。

---

## 6. 怎麼跑起來與驗收

### 環境事實

- 開發機：x86_64 + NVIDIA GeForce RTX 3060 Laptop GPU，Docker 預設 runtime 是
  `runc`（不是 nvidia），所以缺陷 (31) 在這台機器上不會觸發 —— 在 Jetson 或
  任何設了 `"default-runtime": "nvidia"` 的機器上會。
- 三個映像都已在本機：`dianyueguo/orca-auv-rpi-ros2-image`、
  `isaac_ros_dev-x86_64`、`orca-auv-gazebo-simulation-image`。
- 模型檔在 `SAUVC-JETSON/model/`：`finals.onnx`(7類)、`qualification.onnx`(1類)、
  `sim_best.onnx`、`best_conti.onnx`、`best_pretrain.onnx`。

### 完整啟動

```bash
make up            # 起 control + autonomy 容器
make build         # colcon build 兩個 workspace
make sim SEED=42   # build_sim -> Gazebo -> sim_check -> control(sim) -> autonomy
```

`make sim` 會自動處理 `sim_ws` 的建置與 X11 授權。首次啟動 TensorRT 會重建
CUDA engine，**要好幾分鐘**，期間 `/orca/perception_array` 不會有資料。等待
方式：輪詢 `ros2 topic echo --once /orca/perception_array`。

### 讓載具真的動起來

供電鏈是 `decision_node → wrench_sum → 推力分配 → Gazebo`，但 `wrench_sum`
被 supervisor 的模式閘門控制。開機預設是 `SAFE_DISABLED`，**推進器完全沒有
輸出**。要 arm：

```bash
# 注意服務型別是 std_srvs/srv/Trigger，不是 SetBool
ros2 service call /orca_auv/system_manager/set_mode/depth_hold  std_srvs/srv/Trigger
ros2 service call /orca_auv/system_manager/set_mode/autonomous  std_srvs/srv/Trigger
# 應該看到 mode 變成 AUTONOMOUS_AND_DEPTH_HOLD
```

然後啟動任務：

```bash
ros2 topic pub --once /orca/decision/start_mission std_msgs/msg/Bool "{data: true}"
```

### 鏈路健康檢查（各段的預期值）

| 話題 | 預期 |
|---|---|
| `/orca_auv/sensors/imu` | ~100 Hz（**199 Hz 代表有孤兒 bridge**）|
| `/orca/selected/image_raw` | 5–7 Hz（受缺陷 (21) 限制）|
| `/tensor_sub` | 5–8 Hz |
| `/orca/perception_array` | 5–7 Hz |
| `/orca_auv/control/wrench_sources/decision` | 50 Hz |

`ros2 topic info -v /orca_auv/sensors/imu` 的訂閱者清單裡應該要有
`decision_node` —— 這是 IMU remap 有沒有生效的直接證據。

### 驗收「過 gate」

`ARENA=finals SEED=42` 時載具生成在 (-11.75, -5.57)，閘門在 (3.50, -3.04)。
用 `ign model -m navigation_gate -p` 與 `ign model -m orca_auv -p` 讀兩者位姿，
判定條件是：載具的 x 超過閘門的 x **且** 橫向偏差小於閘門半寬 0.75 m。

已驗證可重現的軌跡（兩次獨立執行結果一致）：

```text
 t=1    x=-7.79  y=-5.57   距閘門 -11.29 m
 t=24   x= 0.10  y=-3.80   距閘門  -3.40 m   ← ApproachTarget 收斂到 3 m 停住
 t=67   x= 0.26  y=-3.77   距閘門  -3.24 m   ← FinalAlignTarget 對正
 t=76   x= 4.87  y=-3.02   距閘門  +1.37 m   ← BlindForward 穿過，|dy| = 0.02 m
```

通過後行為樹會進入 `TargetAcquisition` 開始找 `blue_drum` —— 那是
`PassGateProcedure` 回傳 SUCCESS 的證據。

**`SEED=7` 不會通過**，原因是場景遮擋（orange flare 剛好擋在閘門前），不是
程式缺陷。要測穩定性請換多個 seed 並先確認閘門在生成點是可見的。

---

## 7. 踩過的坑

### `sim_check` 的就緒判斷改了三次

判斷「Gazebo 起來了沒」比想像中難，兩種直覺寫法都會誤判：

| 寫法 | 為什麼會誤判 |
|---|---|
| `ros2 topic list \| grep` | control 與 autonomy 都**訂閱**該話題，它們活著就列得出來 |
| `Publisher count` | `ros_gz_bridge` 是獨立於 `ign gazebo` 的程序，Gazebo 死了它照樣掛著發布者 |
| `ros2 topic echo --once` + timeout | ✓ 只有真的有資料流才通過 |

負向測試方式：`pkill -9 -f '[i]gn gazebo'` 之後跑 `make sim_check`，應該要
失敗並印出 `/tmp/sim.log` 的 `process has died`。

### 孤兒程序

`pkill -f 'ros2 launch'` 只殺 launch 父程序，`parameter_bridge` 與
`ign gazebo` 子程序會存活。症狀極難查：重跑一次 `make sim` 之後每個感測器
話題多一個發布者、頻率翻倍，而每一則訊息的內容都完全正常。

`Makefile` 的 `STOP_CONTROL` / `STOP_AUTONOMY` / `STOP_SIM` 都用 `[x]` 括號
技巧避免 pkill 殺掉執行自己的那個 shell —— 動這幾行時不要拿掉括號。

### `sim_best.onnx` 不可用

檔名暗示是用模擬影像訓練的，輸出形狀與 `finals.onnx` 相同（`[1,11,8400]`，
同樣 7 類，可直接替換），但**辨識成功率很低，會把泳池底部的格線辨識成
gate**（使用者目視確認）。症狀是行為樹零星鎖定又立刻丟失，比完全偵測不到
更難查。模擬照樣用 `finals.onnx`。

要改善模擬中的偵測距離，正途是用 `generate_dataset.py` 重新訓練 —— 該工具的
標註缺陷已在本輪修掉（第 3 節第 16 項）。

### 分支保護與遠端 URL

見第 0 節。

---

## 8. 這一輪沒有做的事

- **實機測試**：所有驗收都在模擬中完成，沒有任何一項在真實載具上跑過。
  `SAUVC-RPI#116` 的三項安全修正尤其應該在下水前於實機確認。
- **`micro_ros_agent` 的節點命名**：`bringup.launch.py` 現在會傳
  `name='micro_ros_agent'`，`launch_ros` 因此會附加 `--ros-args -r __node:=`
  到 agent 的命令列，而舊版沒有。這條路徑在模擬中不會執行，值得在實機
  `make launch` 一次確認。
- **資格賽場地的完整驗收**：`--profile qualification` 已通過語法與符號檢查，
  但沒有實際在 `ARENA=qualification` 下跑過資料集產生。
