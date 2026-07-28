# 影音管線架構

## 總入口：`SampleHandler.processSampleBuffer`

```
ReplayKit samples
    │  CMSampleBuffer
    ▼
SampleHandler.processSampleBuffer(_:with:)
    │
    ├── .video ──────────────────────────────► VideoFrameProcessor.process()
    │
    └── .audioApp / .audioMic ──────────────► AudioProcessor.enqueue()
```

- 執行在 ReplayKit 的任意背景佇列（非 main、非特定 serial）
- 每幀提取 `CMSampleTimingInfo`（duration、PTS）
- 各自維護 `videoFrameCount`/`audioFrameCount` 診斷計數器
- 每 1500 幀強制輸出診斷日誌（含 `isActive` 狀態）

---

## 視訊管線

### 資料流

```
SampleHandler
    │
    │  vp.isActive? ──NO──► rebuildVideo() (新 FrameProcessorActor + GPU rotator)
    ▼ YES
VideoFrameProcessor.process(_:originalTime:)
    │
    │  Task { }
    │  │
    │  ▼
    │  FrameProcessorActor.processFrame(imageBuffer:originalTime:angle:)
    │  │
    │  ├── GPU rotator 不存在 → getOrCreateGpuRotator()
    │  │     └── config 變更 → cleanup 舊 rotator，建立新 RPVideoRotatorNV12BatchQueueOptimized
    │  │
    │  ├── rotator.isPermanentlyDead?
    │  │     ├── YES → onPermanentFailure?() → VideoFrameProcessor.isActive = false
    │  │     │          → tryCpuFallback() (RPVideoRotatorCPU_NV12)
    │  │     └── NO  → rotator.rotateAsync()
    │  │                ├── ensureMetalResources() (lazy compile pipeline)
    │  │                ├── await inflightSemaphore.wait() ← 自然 suspend
    │  │                ├── renderPlaneYUV() (Metal compute dispatch)
    │  │                ├── withCheckedContinuation { }
    │  │                │     ├── cmd.addCompletedHandler → resume(rotated)
    │  │                │     └── watchdog 1.0s → resume(nil)
    │  │                └── → CMSampleBuffer?
    │  │
    │  └── return CMSampleBuffer?
    │
    │  guard await mediaMixer.isRunning
    ▼
MediaMixer.append(rotated) → VideoToolbox encode → RTMP
```

### 回退鏈

```
GPU rotator 正常 ──────────────────────────► Metal compute rotation
    │
    ├── 首次失敗 → 自動降品質 bicubic → bilinear
    │
    ├── 5 次連續失敗 → cleanupResources() + metalPermanentFailure = true
    │                  → isPermanentlyDead → onPermanentFailure?()
    │                                     → CPU fallback (vImage)
    │
    └── config 變更 (解析度/旋轉/品質) → cleanup 舊 rotator → 建新 rotator
```

### 背壓

| 機制 | 閥值 | 行為 |
|------|------|------|
| Actor serialization | 自然序列化 | `FrameProcessorActor` 一次只處理一個 frame 的 async chain（`processFrame` → `rotateAsync` → 續） |
| `commandBufferTimeout` | 1.0s | GPU command buffer 逾時 → 回 nil + `handleMetalFailure` |
| `CommandCompletionState` | NSLock | 保證 completion vs watchdog 恰好一次 resume |
| `outputPool` maxPoolSize | 10 | CVPixelBuffer 重用池上限，溢位 evict 最舊 |

#### 為何沒有 in-flight semaphore

早期版本有 `DispatchSemaphore(value:2)` 限制 GPU 同時 in-flight 數量，但分析後發現多餘：

- Actor 已經序列化 frame 處理 — 一次只有一個 frame 在 actor 上執行 async chain
- GPU 旋轉耗時 1-5ms，而 60fps frame 間隔 16.7ms — GPU 有充裕時間完成
- `rotateAsync` 內 `withCheckedContinuation` 已是自然的 backpressure：GPU 完成後才 resume
- Watchdog (1s) 已處理 GPU hang 的罕見狀況，不需要額外 semaphore 做 timeout

移除後管線更簡單：actor → rotateAsync → continuation → completion → append，零隔離衝突。

### 重建路徑

```
SampleHandler 診斷 (每 1500 幀)
    │  vp:Y / vp:INACTIVE
    ▼
vp.isActive == false ──► rebuildVideo()
    │
    ├── videoProcessor = nil
    ├── VideoFrameProcessor(mediaMixer, sendlog)  ← 全新 FrameProcessorActor
    │     └── GPU rotator 全新初始化 → pipeline 重新編譯
    └── 下一幀開始走新管線
```

---

## 音訊管線

### 資料流

```
SampleHandler
    │
    ▼
AudioProcessor.enqueue(sampleBuffer, trackType:, originalTime:)
    │
    │  Task { await actor.enqueue(...) }
    ▼
AudioProcessorActor.enqueue(sampleBuffer, trackType:, originalTime:)
    │
    │  guard mediaMixer.isRunning
    │
    ├── useOriginal == true ─────────────────────────┐
    │     │                                           │
    │     ▼                                           ▼
    │  applyGain(sampleBuffer, trackType:)      audioEngine?.process(sampleBuffer, track:)
    │     │                                           │
    │     │  vDSP_vsmul gain (appAdd/micAdd)          │  Int16→Float→DSP→Float→Int16
    │     │                                           ▼
    │     ▼                                     AsyncStream<ProcessedAudio>
    │  processRMS()                            stream consumer Task:
    │     │                                       │
    │     │  rmsSIMD() → vDSP_measqv               ├── processRMS()
    │     │  VolumeNotifier.updateVolume()          │     rmsSIMD() → VolumeNotifier
    │     ▼                                       ├── mediaMixer.append()
    ▼                                           ▼
MediaMixer.append(processed, track:)
```

### DSP 管線（非原音 `useOriginal == false`）

```
AudioEngine.process(sampleBuffer, track:, originalTime:)
    │
    ▼
AudioPreProcessor.process(sampleBuffer, track:)
    │
    │  Int16 → Float (vDSP_vflt16 + vDSP_vsmul scale)
    │
    ├── track == .app → processApp()
    │     └── echo.updateReference() (保持參考供後續 echo cancel)
    │
    └── track == .mic → processMic()
          ├── echo cancel (EchoCanceller.process)
          ├── noise suppression (RealTimeNoiseSuppressor / MetalRealTimeNoiseSuppressor)
          ├── AGC (AGCProcessor.process)
          └── user gain (applyPostGain)
    │
    │  Float → Int16 (vDSP_vsmul invScale + vDSP_vfix16)
    │
    ▼
yield to AsyncStream<ProcessedAudio>
```

### AudioEngine AsyncStream 消費者

```
AudioProcessorActor.init()
    │
    └── AudioEngine.startStream() → AsyncStream<ProcessedAudio>
    │
    ▼
streamTask = Task { [weak self] in
    for await item in stream {
        guard mediaMixer.isRunning else { continue }
        await processRMS(item.buffer, trackType:, originalTime:)
        await mediaMixer.append(item.buffer, track:)
    }
}
```

---

## `isActive` 失效鏈

```
GPU rotator 連續 5 次 Metal 失敗
    │
    ▼
metalPermanentFailure = true

rotator.isPermanentlyDead → FrameProcessorActor.processFrame() 偵測到
    │
    ├── onPermanentFailure?() ──► VideoFrameProcessor.isActive = false
    │                               (private(set)，sync readable)
    └── tryCpuFallback() (該幀走 vImage)

SampleHandler 診斷日誌: "[VFrame] ... vp:INACTIVE ..."
    │
    │  if vp.isActive == false && !isStopping
    ▼
rebuildVideo()
    │
    ├── 舊 VideoFrameProcessor cleanup
    └── 新的 VideoFrameProcessor (全新 GPU rotator)
```

`onPermanentFailure` 是 `FrameProcessorActor` 的 `let onPermanentFailure: (@Sendable () -> Void)?`，在建構時透過 `nonisolated func setPermanentFailureHandler()` 設定。

AudioProcessor 的 `isActive` 固定為 `true`（audio pipe 無永久失敗路徑，純供 diagnostics 顯示 "Y"）。

---

## 同步/非同步邊界

| 編號 | 位置 | 類型 | 方向 |
|------|------|------|------|
| V1 | `SampleHandler` → `Task { }` | `Task {}` | sync → async |
| V2 | `VideoFrameProcessor` → `actor.processFrame()` | actor boundary | Task → actor executor |
| V3 | `FrameProcessorActor` → `rotator.rotateAsync()` | `async` function | actor → async |
| V4 | `withCheckedContinuation` + `cmd.addCompletedHandler` | C callback → resume | async → sync → async |
| V5 | watchdog `asyncAfter` → resume(nil) | Dispatch timer → resume | timer → async |
| V6 | `await mediaMixer.append(rotated)` | HaishinKit actor/media | Task → encoder |
| A1 | `AudioProcessor` → `Task { await actor.enqueue() }` | `Task {}` | sync → async |
| A2 | `actor` → `audioEngine.process()` | sync method | actor → DSP |
| A3 | `audioEngine` → `AsyncStream.yield()` | continuation yield | DSP → stream |
| A4 | stream consumer Task → `mediaMixer.append()` | HaishinKit API | stream → encoder |

---

## 關鍵檔案對照

| 檔案 | 角色 |
|------|------|
| `SampleHandler.swift` | ReplayKit 入口，分派 video/audio 到對應 processor |
| `VideoProcess.swift` | `VideoFrameProcessor`（外層非 actor）+ `FrameProcessorActor`（actor） |
| `GPUVideoRotator.swift` | Metal 旋轉 pipeline、output pool、`inflightSemaphore`、watchdog |
| `CPURotator.swift` | vImage CPU 旋轉 fallback |
| `AudioProcess.swift` | `AudioProcessor`（外層非 actor）+ `AudioProcessorActor`（actor）+ `VolumeNotifier` |
| `AudioNoiseFix.swift` | `AudioEngine` + `AudioPreProcessor` + DSP 元件（AGC、Echo、Noise Suppressor） |
| `AsyncSemaphore.swift` | 自訂 async-aware semaphore，`CheckedContinuation` 掛起取代 blocking |
