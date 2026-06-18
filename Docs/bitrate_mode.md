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
