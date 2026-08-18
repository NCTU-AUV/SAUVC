# Foxglove layout

`orca.json` —— 四個分頁的單一 layout，給 **mcap bag 離線分析**用。
針對 Foxglove **2.59.0** 的 schema 撰寫（2.x 的 Image 面板用
`imageMode.imageTopic`，不是 Studio 1.x 的 `cameraTopic`）。

## 匯入

Foxglove 左上 layout 選單 → **Import from file…** → 選 `foxglove/orca.json`。
然後 **Open local file** 開 `bags/orca_*/` 底下任一個 `.mcap`。

## 分頁

| 分頁 | 回答的問題 |
|---|---|
| 感知 · gate | 偵測到了嗎？深度過得了 `_estimate_gate` 嗎？行為樹當下在哪個節點？ |
| 任務進度 | 行為樹走過哪些節點、目標何時鎖定、系統模式與安全旗標的時間軸 |
| 控制 · 深度 PID | 目標 vs 實際深度、wrench 匯流排各來源的貢獻、八軸推進器出力 |
| 賽後回放 | 影像、決策、控制排在同一條時間軸上對時 |

「感知 · gate」那頁的重點是 `distance` 與 `valid` 兩條：`distance = -1`
代表 `_estimate_gate` 拒絕了這一幀（不是沒偵測到），而 `is_stable` 決定它
進不進得了世界模型。三者分開看才能區分「沒看到」「看到但深度被拒」
「深度有效但不穩定」。

## 前提

- **影像面板需要 `RECORD_IMAGES=true` 錄的 bag。**沒開的話那幾個面板會是空的，
  其餘面板照常。
- `/orca/decision/status` 與 `/orca/perception_array` 是 `orca_interface` 型別。
  這兩條在 2026-08-14 之前錄的 bag 裡**不存在** —— 當時 `orca_interface` 沒有
  build 進 control 容器，`ros2 bag record` 會靜默跳過它們（只在 launch log 留下
  "has unknown type"）。舊 bag 開起來這兩類面板會是空的。
- 沒有 TF tree（堆疊裡沒有 `robot_state_publisher` 也沒有 URDF），所以沒有放
  3D 面板 —— 放了也沒東西可畫。

## 改動 layout 之後

在 Foxglove 裡調好版面 → layout 選單 → **Export to file…** → 覆蓋 `orca.json`。
匯出的是 `{configById, globalVariables, userNodes, playbackConfig, layout}`
這層，不含 `id`/`name`/`baseline` 外殼。
