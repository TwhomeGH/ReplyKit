# 影片尺寸設計：AD / OD

本文整理 ReplyKit 影片尺寸設定的語意，避免把 GPU 中間處理尺寸誤當成最終輸出解析度。

## 欄位語意

| App Group / Socket 欄位 | Extension 狀態 | 用途 |
| --- | --- | --- |
| `dstW` / `dstH` | `ADWidth` / `ADHeight` | GPU 旋轉/縮放的中間處理尺寸 |
| `odstW` / `odstH` | `ODWidth` / `ODHeight` | 最終畫布尺寸，也是 encoder `videoSize` 優先套用的輸出解析度 |

`dstW` / `dstH` 可以依照 ReplayKit 原始畫面比例或裝置特性設成非標準 16:9。  
`odstW` / `odstH` 才是 RTMP metadata、VideoToolbox encoder 與最終輸出影片應該呈現的尺寸。

## 套用規則

### Encoder

encoder `videoSize` 一律優先使用 `odstW` / `odstH`：

1. `odstW > 0 && odstH > 0` 時，輸出尺寸使用 OD。
2. OD 沒有成對有效時，才 fallback 到 `dstW` / `dstH`。
3. OD 或 AD 都必須寬高成對有效，不可混用 `ODWidth + ADHeight` 或 `ADWidth + ODHeight`。

### GPU Rotator

GPU rotator 同時接收兩組尺寸：

- `dstWW` / `dstHH`：GPU 中間處理尺寸，來源是 AD。
- `OutWW` / `OutHH`：最終畫布尺寸，來源是 OD。

runtime 更新時必須同時刷新 AD 與 OD，避免 encoder 已經切到新畫布，但 rotator 還停在舊處理尺寸。

## Runtime 同步

`OutW` 與 `OutH` 是兩個獨立 Darwin Notification，但 Extension 端不能只更新單一軸。  
每次收到任一事件時，都要一次讀齊四個欄位：

- `dstW`
- `dstH`
- `odstW`
- `odstH`

讀齊後再原子套用：

- 更新 `ADWidth` / `ADHeight`
- 更新 `ODWidth` / `ODHeight`
- 更新 encoder `videoSize`
- 更新 rotator 的 AD / OD 尺寸

這樣可以避免 `OutW` 先到、`OutH` 後到時產生 `(新寬度, 舊高度)` 的暫態解析度。

## Preset 對照

| Preset | GPU 處理尺寸 (`dstW` / `dstH`) | 畫布/encoder 輸出尺寸 (`odstW` / `odstH`) |
| --- | --- | --- |
| 720p 16:9 | 1034 x 720 | 1280 x 720 |
| 1080p 16:9 | 1552 x 1080 | 1920 x 1080 |

例如 `1080p 16:9` preset 使用 `1552x1080` 做 GPU 中間處理，但輸出的 RTMP metadata 與影片解析度必須是 `1920x1080`。如果分析工具看到 `1080x1552`，通常代表 `dstW` / `dstH` 被錯套到 encoder，並且又被旋轉資訊轉置。

## 相關實作

- `liveAPP/Setting.swift`：設定頁維護 `dst*` 與 `odst*`。
- `liveAPP/Socket.swift`：把兩組尺寸送到 Broadcast Extension。
- `ReplyKIT/SampleHandler.swift`：讀取完整尺寸並套用 encoder。
- `ReplyKIT/VideoProcess.swift`：同步 rotator 的 AD / OD 尺寸。
