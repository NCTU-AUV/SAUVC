# 資格賽過門：問題診斷與解法

> 日期：2026-08-31 ／ 分支 `feat/sync-main-dev`（未提交）
> 場地 `ARENA=qualification`、7 類 `finals` 模型、閘門橫桿已改為對齊水面（z=0.0）
> 本文所有數字都來自本次實測，不是推估；推論性的段落會明確標示。

---

## 摘要

以 `QualificationMissionGateOrFlares` 跑了 6 輪（5 輪 + 1 輪重測）。

**行為樹的分支切換是有效的**：6 輪裡 5 輪確實從「整門框」路線交棒到「柱子配對」路線，
交棒時間 75～93 秒，與 90 秒上限吻合。

**但沒有任何一輪靠柱子配對過門。** 原因不在行為樹，也不在標籤，而在
**感知輸出的資料量根本不足以支撐任何一條視覺路線**。

---

## 1. 問題是什麼

三層，由下而上。上層的問題都是下層造成的。

### 1.1 物理層：柱子在起跑點只有 2 個像素寬

閘門立柱直徑 4 cm（`q_gate/model.sdf`：`radius 0.02`）。
RealSense 彩色 HFOV 約 69.4°，640 寬張量的焦距約 462 px。

| 到門的距離 | 柱子寬度 | 門開口寬度 |
|---|---|---|
| **9.46 m（起跑點）** | **1.9 px** | 73 px |
| 5 m | 3.7 px | 138 px |
| 3 m | 6.2 px | 231 px |

載具起跑時，要偵測的目標是**兩根寬度 2 像素的垂直細絲**。
640×640 的 YOLOv8 在這個尺度上不可能穩定 —— 這不是調參數能解決的，是解析度的下限。

實測到的框長寬比中位數 12～24（換算成「10 px 寬、235 px 高」這種形狀），
正是這個現象的直接證據。對照決賽 bag 裡真正的 flare 是 3～5。

### 1.2 感知層：87% 的偵測進不到決策層

30 秒（184 影格）的標籤普查：

```
每影格 gate 框數:            {0: 178, 1: 6}          ← 96.7% 的影格完全看不到門
每影格細長框(h/w>=1.8) 數:   {0: 116, 1: 54, 2: 14}

標籤          偵測數   h/w 中位數   通過 is_stable
yellow_flare    59       23.56           6
red_flare       13       23.82           4
gate             6        6.15           1
blue_flare       5       12.42           0
合計            83                      11   (13%)
```

`WorldModel::updateFromPerception`（`orca_decision/src/world_model.cpp:20`）
**只接受 `is_stable == true` 的物件**，其餘直接丟棄。所以決策層實際看到的是 83 個裡的 11 個。

值得注意的是，模擬用的 `simulation_params.yaml:115-118` 穩定度設定**已經相當寬鬆**：

```yaml
stability_window:         6      # 只看最近 6 幀
stability_min_hits:       2      # 出現 2 幀就算
stability_pos_std_thresh: 0.30   # 位置標準差上限 0.30 m
stability_conf_thresh:    0.25
```

（真機用的 `perception_params.yaml` 才是嚴格的 10 幀／7 次／0.15 m。**不要拿那份的數字來判斷模擬結果**。）

既然門檻已經這麼鬆卻仍有 87% 被擋下，**推測**主要卡在 `stability_pos_std_thresh`：
一個 2 像素寬的物體，深度估計本來就是雜訊，位置標準差輕易就超過 0.30 m。
*此點尚未隔離驗證* —— 要確認需要在 `depth_perception` 裡分別記錄「命中次數不足」與
「位置變異過大」各自擋掉多少。

### 1.3 決策層：世界模型的同標籤覆寫，讓跨影格配對不可能

`world_model.cpp:25-32`：新訊息裡只要出現某個標籤，就會**先刪光所有既有的同標籤物件**，
再塞入這一幀的。

後果：第 1 幀看到左柱（標成 `yellow_flare`），第 2 幀看到右柱（也是 `yellow_flare`）——
第 2 幀會把左柱刪掉。**同標籤的兩根柱子永遠無法跨影格湊成一對。**

這正好解釋了實測數字：

- 至少一個細長框的影格：**37%**（54+14 of 184）
- 兩個細長框同時出現的影格：**7.6%**（14 of 184）

配對率被鎖死在 7.6% 這條線上，而不是接近 37%。物件本來就會保留 1 秒
（`perception_timeout_sec: 1.0`），但這個覆寫把跨影格累積的效果抵銷掉了。

---

## 2. 不是問題的東西

測試過程中被排除的幾個假設，記錄下來避免重複繞路。

| 假設 | 結論 |
|---|---|
| 「兩根 flare 辨識不出來」 | **不成立。** flare 標籤確實會出現（`yellow_flare` 59 次），儘管資格賽池裡沒有任何 flare 實體 —— 那些是誤判。問題不是認不出來，是整體偵測量太少 |
| 「標籤設錯了」 | **不成立。** 標籤清單 `gate,red_flare,blue_flare,yellow_flare,orange_flare` 已涵蓋實際吐出的全部標籤。標籤不是瓶頸 |
| 「柱子配對邏輯有錯」 | **不成立。** 該邏輯以合成資料測過三個案例（選最近的一對、拒絕中間卡東西的配對、濾掉寬框），全部通過。它拿不到輸入，不是算錯 |
| 「橫桿貼水面是元兇」 | **未驗證。** 本次量測是在橫桿移到水面之後做的，沒有同條件的前後對照。要驗證只需把 `entity_spawner.py` 的 spawn z 改回 `-0.08`，重跑同一份 30 秒普查比對 |

另外，整門框路線在橫桿貼水面後**並沒有完全失效** —— 每一輪 `SearchTarget`/`ApproachTarget`
都反覆抓到 `gate`，只是不穩（debug 持續出現 `Target lost: gate`），表現為 Search↔Approach 來回震盪。

---

## 3. 一個必須先補的缺陷

`AcquireGateByPostPair` 裡的 `SearchGateByPosts` **沒有包 Timeout**，
而它跟 `SearchTarget` 一樣**永遠不會回傳 FAILURE**（找不到就無限期回傳 RUNNING）。

後果：配不到柱子時**整個任務無限期掛住**。本次 6 輪裡有 5 輪是被外部 2 分鐘上限
強制中止的 —— 實機上沒有那個外部上限。

修法（`trees.xml`，整門框分支已經有同樣的保護）：

```xml
<Timeout msec="60000">
  <SearchGateByPosts label="gate,red_flare,blue_flare,yellow_flare,orange_flare"/>
</Timeout>
```

**這一項與採取哪個策略無關，一定要補。**

---

## 4. 解法

### Tier 1｜純軟體、不動感知設定

**A. 修掉世界模型的同標籤覆寫**（`world_model.cpp:25-32`）

不要按標籤整批刪除，改成按影像位置關聯（同標籤且 cx/cy 相近才視為同一物件的更新）。

- 成本：中（要在 `WorldModel` 加一層簡單的關聯邏輯）
- 預期：把配對機會從 7.6% 往 37% 推。**這是目前唯一能在不改善偵測品質的前提下，
  顯著提高配對率的手段**

### Tier 2｜改變戰術：接受「這個距離就是看不到」

**B1. 先靠幾何逼近，再開始看**

資格賽場地是**固定的**（`entity_spawner.py:151-169`）：載具在 x=-11.96，門在 x=-2.5，
同一個 y，yaw=0 正對著門。這些都是已知的，不需要看到門。

先航位推算前進約 6 m，剩 3.5 m 再啟動視覺 —— 那時柱子有 5～6 px 寬、開口 200 px，
偵測條件與起跑點完全不同。

**B2. 資格賽乾脆不用視覺**（建議優先驗證）

任務只是「過門兩次」。門寬 1.5 m，載具要在 9.46 m 內維持 ±0.75 m 橫向精度，
即航向誤差需小於 **4.5°**。

但 `decision_params.yaml:27` 的 `align_yaw_threshold` 目前是 **0.1 rad = 5.7°**，
**比需求還鬆** —— `TurnToYaw` 收斂到這個門檻就結束，殘餘誤差在 9.46 m 的直線上
會累積成超過半個門寬的側偏。

作法：收緊到 0.05 rad，搭配 `BlindForward` 的 `heading_lock`，
跑 `QualificationMissionBlindReturn`。

以目前 37%／7.6% 的偵測狀況，**純航位推算的過門成功率很可能高於現行視覺鏈**。

### Tier 3｜感知端

- `simulation_params.yaml:71` 的 `confidence_threshold: 0.25 → 0.15`：
  最便宜的一次嘗試，先看原始偵測數是否明顯上升
- 隔離驗證 `is_stable` 到底卡在哪一項（命中次數 vs 位置變異），再決定要不要放寬
- 長期真正的解法是重訓，但要先確認訓練資料裡是否包含
  「遠距離、細如髮絲、橫桿貼水面」這種外觀。目前模型顯然沒學過

---

## 5. 建議執行順序

1. **補 Timeout**（第 3 節）—— 必要，與策略選擇無關
2. **試 B2** —— 收緊 `align_yaw_threshold` 到 0.05，跑 `QualificationMissionBlindReturn` 5 輪。
   這是最快能得到「資格賽到底過不過得了」這個底線答案的路徑
3. **修 A + 重新量配對率** —— 再決定視覺這條路值不值得繼續投資
4.（可選）**橫桿位置的前後對照** —— 釐清 1.1 的嚴重程度有多少是這次改動造成的

---

## 附錄 A：6 輪測試原始結果

| 輪 | 起始線 | 切換到 post_pair | 配到柱子對 | 結束 | 卡在 |
|---|---|---|---|---|---|
| 1 | y=-3.0 | 否 | — | 疑似完成¹ | `BlindForward` |
| 2 | y=-3.0 | 是（75.3 s）² | 0 次 | stalled | `SearchGateByPosts` |
| 3 | y=-3.0 | 是（92.6 s） | 55 次，gap 146–178 px | stalled | `SearchGateByPosts` |
| 4 | y=-3.0 | 是（91.1 s） | 0 次 | stalled | `SearchGateByPosts` |
| 5 | y=+3.0 | 是（91.0 s） | 0 次 | stalled | `SearchGateByPosts` |
| 1 重測 | y=-3.0 | 是（92.2 s） | 5 次，gap 149–189 px | stalled | `SearchGateByPosts` |

¹ 見附錄 B。² 較早交棒是因為 `RetryUntilSuccessful num_attempts="6"` 先耗盡，早於 90 秒上限。

「stalled」一律是外部 2 分鐘無動作上限觸發，不是行為樹自己結束的。

## 附錄 B：一個觀測陷阱（會誤判成當機）

`decision_node.cpp:334` 的 `publishWrenchLoop` 在 `mission_started` 轉為 false 之後就提前
return，而 `btTickLoop`（`decision_node.cpp:310-313`）在任務完成時是
**先清掉那個旗標，再寫入 `MissionComplete`**。

結果：**`MissionComplete` 永遠不會出現在 `/orca/decision/status` 上。**
那個 topic 在結果揭曉的瞬間變靜默，從外部看跟節點當掉完全一樣。

只有 `/orca/decision/status_json` 帶得到最終狀態（它在提前 return 之前發布）。
程式註解本身就記載了這件事。

第 1 輪原本被標成 stalled，很可能其實是**跑完了**（它已走完
`BlindForward → TurnToYaw → BlindForward`）。改用 `status_json` 重測後同一個 SEED
沒能重現該次成功，所以這一格只能標「疑似」。

**任何監看 `/orca/decision/status` 的外部工具都有這個陷阱。**

## 附錄 C：量測方法

- **標籤普查**：訂閱 `/orca/perception_array` 30 秒，統計每個標籤的偵測數、
  框長寬比中位數、`is_stable` 通過數，以及每影格的細長框數分布
- **每輪測試**：`make sim ARENA=qualification SEED=n HEADLESS=true` →
  呼叫 `/orca_auv/system_manager/set_mode/autonomous` →
  發布 `/orca/decision/start_mission` → 監看 `status_json` 的
  `current_action` 轉換，2 分鐘無變化即中止該輪
- **分支判定**：`SearchTarget`/`ApproachTarget`/`FinalAlignTarget` → 整門框分支；
  `SearchGateByPosts`/`ApproachGateByPosts`/`AlignGateByPosts` → 柱子配對分支
- 焦距 462 px 由 HFOV 69.4° 與 640 寬張量推得，用於本文所有像素↔公尺換算
