# 位元率模式說明

## 模式一覽

| 模式 | 值 | HaishinKit | 特性 | 適合 |
|------|----|------------|------|------|
| ABR | 0 | `.average` | 長期貼近目標 bitrate，允許短期波動 | **推薦** — 直播首選，穩定與畫質的平衡 |
| CBR | 1 | `.constant` | 嚴格維持固定 bitrate，波動最小 | 上傳頻寬極度受限或不穩定的環境 |
| VBR | 2 | `.variable` | 依場景複雜度自由分配 bitrate，畫質最佳 | 錄製/本地存檔，不適合即時串流 |
| Quality | 3 | `.quality` | 依品質係數（0.0~1.0）控制編碼 | 不限制 bitrate 的場景 |

## 實測數據（目標 6000 Kbps）

| 模式 | Avg | Max | 倍率 |
|------|-----|-----|------|
| ABR | ~6000 | ~8500 | ~1.4x |
| CBR | ~6000 | ~6500 | ~1.08x |
| VBR | ~6000 | ~17000+ | ~2.8x+ |

## 建議

- **預設使用 ABR** — 跟 Twitch/YouTube 官方建議一致，峰值能被壓住，畫質也夠好
- VBR 的 bitrate 爆衝（3x 以上）在 live 場景容易造成：
  - RTMP 延遲升高
  - 上傳 buffer 累積
  - 觀眾端卡頓／斷流
- 如果切 ABR 後延遲或斷流問題仍存在，再換 CBR
- Quality 模式直接設 0.0~1.0 品質係數（不設 bitrate），適合純區域網路串流

## 程式碼對照

`ReplyKIT/SampleHandler.swift:1386-1399`：

```swift
switch RPConfig.shared.state.BitRateMode {
case 0: videoSettings.bitRateMode = .average
case 1: videoSettings.bitRateMode = .constant
case 2: videoSettings.bitRateMode = .variable
case 3: videoSettings.bitRateMode = .quality
default: videoSettings.bitRateMode = .average
}
```

`liveAPP/Setting.swift:645`：

```swift
let BitRateOptions = [
    "ABR 平均碼率 VBR的改進版",
    "CBR 固定碼率",
    "VBR 可變位元率",
    "Quality 品質模式"
]
```

## 備註

- VBR / Quality 在 fork 版本中已移除 iOS 26 限制，iOS 13+ 均可使用

## MyStreamBitRateStrategy（2026-08 精簡為純統計）

### 設計

`MyStreamBitRateStrategy` 現在**僅做統計，不做碼率調整**。壅塞處理由 HaishinKit fork 內部的 `SocketBackpressure`（三級丟幀：512KB 節流 / 1MB 停 video / 1.28MB 停 audio）負責，此策略只收集 `NetworkMonitor` 的統計數據並節流輸出日誌。

### 移除內容（2026-08）

| 項目 | 理由 |
|------|------|
| 動態升降碼率邏輯（`stepUp` / `minBitrate` / ring buffer / warmup / `minBitrateHoldDuration`） | 調整由 fork 內建策略或 SocketBackpressure 取代 |
| `.publishInsufficientBWOccured` 降速 | 原實作的 `smoothBps` 平滑計算是空操作（`measuredBps == avgOutBps`），且無冷卻會連續降速 |
| 斷線監控（`checkDisconnect` / `setOnDisconnect` / `disconnectMonitorTask` / `startDisconnectMonitor`） | callback 只 log、無實質動作，RTMPConnection 已有完整重連狀態機 |
| `isChangBit` / `updateVideoBitRate` / `updateAudioBitRate` | 無調整功能後失去意義 |

### 保留功能

- 指數移動平均 `avgOutBps`（tau=3s）— 平滑統計值
- 統計日誌節流：每 10 次 `status` 事件才寫一次 log（`statsLogInterval = 10`）

### 程式碼位置

`ReplyKIT/BitRateStrategy.swift` — `adjustBitrate` 僅處理 `.status`，其他事件直接忽略。


# 建議位元率設定（VBR 模式）

在使用 VBR（Variable Bitrate，可變位元率）時
不能直接套用與 CBR（Constant Bitrate，固定位元率） 或 ABR（Average Bitrate，平均位元率） 相同的數值。

例如：

- 如果你的目標是 6000 kbps，在 VBR 模式下建議設定為 一半左右（約 3000 kbps）。

- 這樣實際輸出會落在 3000 ~ 6000 kbps 的合理範圍。

- 若直接設定成 6000 kbps，VBR 在高複雜度場景可能會飆升到 10000 kbps 以上，導致檔案過大或超出預期。