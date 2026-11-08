# 音量控制頁說明

## 目的

音量控制頁用於調整直播輸出的 App 音訊與麥克風音訊，並監看 ReplayKit extension 回報的即時 RMS 音量。

此頁面同時處理兩種不同概念：

| 類型 | 對應設定 | 用途 |
| ------ | ---------- | ------ |
| 輸出音量 | `appVolume` / `micVolume` | 控制最終混音輸出比例，範圍為 `0.0...1.0` |
| 增益放大 | `appAddVolume` / `micAddVolume` | 對原始音訊做 boost-only 放大，主要用於來源音量過低時補償 |
| 即時音量 | `appVolumeLive` / `micVolumeLive` | ReplayKit extension 回報的 RMS 音量，用於視覺監看 |

## 為什麼不用線性百分比

人耳對音量的感受接近對數，而不是線性。若使用一般 `0...100%` 且每格 `1%` 的線性滑條，低音量區會太粗，像是 `0.01%`、`0.00001%` 這類常見於音訊衰減需求的值很難精準設定。

舊版使用 `sqrt` 類型曲線：

```swift
realVolume = sqrt(sliderValue)
```

這會讓低段更粗。例如 UI 的 `1%` 會變成真實音量約 `10%`，反而不利於小音量控制。

新版改用 dB 對數映射：

```swift
realVolume = pow(10, decibels / 20)
```

滑條位置均勻對應 dB，讓低音量區有足夠精度，高音量區也保持自然手感。

## 映射公式

目前最低非零音量設定為：

```swift
minimumAudibleVolume = 0.01
```

也就是 `-40 dB`。滑條值 `0` 代表完全靜音，`50%` 約 `-20 dB`，`100%` 是 `0 dB`。這樣 `-38.9 dB` 會落在左端約 `2.7%`，不再出現在滑條中段。

UI 百分比轉真實音量：

```swift
let minimumDecibels = 20 * log10(minimumAudibleVolume)
let decibels = minimumDecibels + (0 - minimumDecibels) * sliderValue
let realVolume = pow(10, decibels / 20)
```

真實音量轉 UI 百分比：

```swift
let decibels = max(20 * log10(realVolume), minimumDecibels)
let sliderValue = (decibels - minimumDecibels) / -minimumDecibels
```

## 對應表

以下表格以目前 `minimumAudibleVolume = 0.01` 計算：

| 滑條位置 | 真實音量比例 | 真實音量百分比 | 約略 dB |
| ---------- | -------------- | ---------------- | --------- |
| 0% | 0 | 0% | 靜音 |
| 10% | 0.015849 | 1.58% | -36 dB |
| 20% | 0.025119 | 2.51% | -32 dB |
| 30% | 0.039811 | 3.98% | -28 dB |
| 40% | 0.063096 | 6.31% | -24 dB |
| 50% | 0.1 | 10% | -20 dB |
| 60% | 0.158489 | 15.85% | -16 dB |
| 70% | 0.251189 | 25.12% | -12 dB |
| 80% | 0.398107 | 39.81% | -8 dB |
| 90% | 0.630957 | 63.10% | -4 dB |
| 100% | 1.0 | 100% | 0 dB |

滑條中段現在是 `-20 dB`，不是線性的 `50%` 振幅；這是刻意保留 dB 精度，但把範圍縮到實際可用的 `-40…0 dB`。

## UI 顯示策略

音量頁會同時顯示兩種數字：

| 顯示 | 含義 |
| ------ | ------ |
| `App音量` / `Mic音量` | 滑條位置；UI 左端標示靜音，中點約 -20 dB，右端 0 dB |
| `原始` | 真實寫入 mixer 的音量比例 |

小音量顯示會依大小自動增加小數位，避免 `0.00001%` 類型的值被格式化成 `0.00%`。

## 音量條視覺化

輸出音量條和即時 RMS 音量條都使用 `volumeToPercentage` 轉成視覺比例後再繪製。

原因是如果直接使用真實線性音量繪製，`0.00001%` 到 `1%` 之間幾乎都會看起來是空的。使用相同的 dB 視覺映射後，低音量區的變化可以被看見，使用者比較容易確認控制正在生效。

## 日誌顯示

socket 收到的 `appVol` / `micVol` 是 extension 回報的真實線性 RMS 音量，不是滑條百分比。小音量可能會被 Swift 預設格式顯示成科學記號，例如：

```text
app=2.7189059e-05
```

這代表真實線性值 `0.000027189059`，也就是 `0.00271891%`，約 `-91.31 dB`。為了避免誤判為公式錯誤，音量相關日誌應同時顯示：

```text
app=0.00002719 (0.00271891%, -91.31 dB)
```

## 維護注意事項

- `appVolume` / `micVolume` 的儲存值仍然維持真實線性比例 `0.0...1.0`，不要改成直接儲存 dB 或 UI 百分比，避免破壞 `MediaMixer` 介面。
- `liveAPP/ContentView.swift` 和 `ReplyKIT/AudioProcess.swift` 內的換算函式要保持一致，否則主 App 顯示和 extension 日誌會出現不同解讀。
- `appAddVolume` / `micAddVolume` 是增益放大，不是一般音量衰減。它們維持 `1...30` 倍的 boost-only 語意。
- 若未來要調整可控範圍，優先調整 `minimumAudibleVolume`，並同步更新本文的對應表。
