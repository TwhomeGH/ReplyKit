# Metal Shader 性能優化

## 2026.07.30 三項改進

### 1. 移除 `unsharpY` 死碼

**檔案：** `ReplyKIT/rotateNV12.metal`

`kernel void unsharpY` 已編譯進 Metal library 但 Swift 端從未呼叫。移除後減少 Metal library 編譯時間與 binary size。

相關：`catmullRom1D_uv` helper function 也一併移除（僅被 `bicubicSampleUV_16tap` 使用）。

### 2. Threadgroup 大小最佳化

**檔案：** `ReplyKIT/GPUVideoRotator.swift:884`

```
// 改前
let tgWidth = min(compute.threadExecutionWidth, 32)

// 改後
let tgWidth = compute.threadExecutionWidth
```

舊 code 硬 cap 在 32，在 M 系列 GPU（threadExecutionWidth = 64）上只用了一半 SIMD 頻寬。改為直接使用 GPU 回報的最佳寬度：

| GPU | threadExecutionWidth | 改前 | 改後 |
|-----|---------------------|------|------|
| A14-A17 | 32 | 32 | 32 (不變) |
| M1-M4 | 64 | 32 | 64 |

### 3. UV 平面 16-tap bicubic → 4-tap bilinear 近似

**檔案：** `ReplyKIT/rotateNV12.metal`

#### 改動
- 移除 `bicubicSampleUV_16tap()`（完整 16-tap Catmull-Rom）
- 新增 `bicubicSampleUV_4tap()`（利用 bilinear 硬體逼近 bicubic）
- `rotateNV12_bicubic` kernel 改用 4-tap

#### 原理

NV12 的 UV 平面解析度只有 Y 的 1/4（寬高各半），對它做完整 16-tap Catmull-Rom 的視覺回報極低。Y 平面早已使用相同的 4-tap 手法（`bicubicSampleY_4tap`），UV 比照辦理。

| 指標 | 16-tap | 4-tap |
|------|--------|-------|
| texture sample 次數 | 16 | 4 |
| 乘加運算 | ~80 | ~20 |
| 視覺差異 | baseline | 極小（UV 解析度低） |

#### 效能影響

假設輸出 1080p（1920×1080）：
- UV 平面 thread count = 960 × 540 = 518,400
- 每個 thread 少 12 次 texture sample → 總計每秒減少約 6.2M 次 texture sample（@60fps）

## 2026.09.07 視訊管線健康診斷與低風險瘦身

### 1. `[VHealth]` 視訊健康分類

**檔案：**

- `ReplyKIT/SampleHandler.swift`
- `ReplyKIT/VideoProcess.swift`
- `ReplyKIT/GPUVideoRotator.swift`
- `liveAPP/Socket.swift`
- `liveAPP/OtherView.swift`

新增每秒一次的視訊管線健康樣本，用於區分卡頓來源：

| 狀態 | 判斷方向 | 含義 |
|------|----------|------|
| `healthy` | input / processed 接近，無 timeout | 管線正常 |
| `upstream-throttle` | input fps < 20 且 Metal timeout 未增加 | ReplayKit 上游擷取被系統/GPU 排程節流 |
| `metal-pressure` | Metal timeout 增加或 in-flight 過高 | 我們的 Metal command buffer 正在受壓 |
| `processor-pressure` | input 正常但 processed 明顯低於 input | 旋轉/MediaMixer 前段處理追不上 |
| `processor-drop` | 單秒內有 drop | 處理器有丟幀，但尚未符合更明確分類 |

extension 同時輸出人工可讀 log，僅供日誌觀察：

```text
[VHealth]: upstream-throttle input:8.0fps processed:8.0fps dropped:0.0fps timeoutDelta:0 ...
```

設備信息頁不解析 log 字串；圖表資料只透過 E-Socket 的結構化 `videoHealth` payload 更新。這可以避免 log 格式調整時破壞 telemetry。

### 2. 設備信息頁圖表

**檔案：** `liveAPP/OtherView.swift`

新增 `VideoHealthModel`，保留最近 120 秒：

- input fps
- processed fps
- dropped fps
- Metal timeout delta
- 最新狀態

設備信息頁新增 `Video Pipeline` 區塊，用 Swift Charts 顯示 FPS 趨勢與 timeout/s。這可以用來快速判斷遊戲吃滿 GPU 時，到底是 ReplayKit 上游沒給幀，還是我們自己的 Metal command buffer 開始 timeout。

### 3. 移除未使用的 16-tap Y bicubic helper

**檔案：** `ReplyKIT/rotateNV12.metal`

移除未被 kernel 呼叫的 `bicubicSampleY_16tap()`。目前 bicubic kernel 的 Y/UV 都走 4-tap 硬體 bilinear 近似，保留 16-tap helper 只會增加 shader library 體積與維護混淆。

### 4. Output texture usage 精準化

**檔案：** `ReplyKIT/GPUVideoRotator.swift`

建立 output `CVPixelBuffer` 時加入：

```swift
kCVMetalTextureUsage as String: NSNumber(value: MTLTextureUsage.shaderWrite.rawValue)
```

讓 Metal/CoreVideo 知道這批 output texture 的主要用途是 compute shader write，避免 usage 過寬導致 driver 無法做最佳化。

### 5. 記憶體診斷改為 resident memory

`memorySnapshot()` 原本輸出 `ProcessInfo.processInfo.physicalMemory`，那是裝置總 RAM，不是 extension 目前使用量。現在改用 `task_info(MACH_TASK_BASIC_INFO)` 回報 resident memory，Metal failure log 更有診斷價值。
