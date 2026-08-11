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
    │  │                ├── renderPlaneYUV() (Metal compute dispatch)
    │  │                ├── withCheckedContinuation { }
    │  │                │     ├── cmd.addCompletedHandler → resume(rotated)
    │  │                │     └── watchdog 1.0s → resume(nil)
    │  │                └── → CMSampleBuffer?
    │  │
    │  └── settle(result:)  ← 凍結幀 fallback 判定
    │        ├── 成功 → consecutiveDropCount = 0 + storeLastGoodSnapshot() (deep copy)
    │        ├── 失敗且 < 3 幀 → return nil (丟棄)
    │        ├── 失敗且 3..<60 幀 → makeFallbackSampleBuffer() 重打目前 PTS 送凍結幀
    │        └── 失敗且 ≥ 60 幀 → onPermanentFailure?() → return nil (標記重建)
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
    ├── 連續 3 幀失敗 (≤60) → 最後好幀 freeze fallback
    │     └── 重打「目前幀 PTS」+ decodeTimeStamp invalid → 時間軸連續
    │         → 避免 RTMPStream stall 偵測 (videoInputFrames==0) 誤觸發 restartVideoPipeline
    │
    ├── 5 次連續 Metal 失敗 → cleanupResources() + metalPermanentFailure = true
    │                  → isPermanentlyDead → onPermanentFailure?()
    │                                     → CPU fallback (vImage)
    │
    ├── 連續 60 幀 freeze 仍失敗 → onPermanentFailure?() → 標記重建
    │
    └── config 變更 (解析度/旋轉/品質) → cleanup 舊 rotator → 建新 rotator
```

#### 最後好幀 freeze fallback

- **觸發**：`processFrame` 回傳 nil（GPU 逾時 / Metal 失敗 / CPU fallback 也失敗），`consecutiveDropCount` 在 3..<60 之間。
- **內容**：`lastGoodSnapshot` 是上次成功旋轉幀的 **deep copy**（`copyPixelBuffer` 逐 plane memcpy），不能用 sample buffer 參照 — GPU output pool 會重用 CVPixelBuffer，直接留參照會被下一幀覆寫。
- **時間戳**：`makeFallbackSampleBuffer` 用 `CMSampleBufferCreateReadyWithImageBuffer` 重打**目前幀的 PTS**（`presentationTimeStamp: pts`、`decodeTimeStamp: .invalid`、duration 沿用目前幀）。絕不能用舊幀 PTS，否則 `RTMPTimestamp.update` 偵測 `value <= updatedAt` 走 invalid sequence 重置 → Non-monotonous DTS → 碼率爆衝假象。
- **效果**：GPU 真卡住時下游仍持續收到幀 → `RTMPStream.videoInputFrames > 0`，不會觸發 `interval > 3s && videoInputFrames==0` 的 encoder restart；GPU 恢復後 PTS 平滑銜接無跳動。缺點是畫面停在最後好幀（凍結），這是「凍結但連續」對「無聲停滯」的取捨。

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
    │     │  更新 lastAppRMS/lastMicRMS             │     rmsSIMD() → 更新 lastRMS
    │     │  VolumeNotifier.updateVolume()          │     VolumeNotifier.updateVolume()
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
```

另一條失效鏈：`settle()` 中 `consecutiveDropCount >= 60`（GPU 與 CPU fallback 皆連續失敗）→ 同樣呼叫 `onPermanentFailure?()` 標記重建。

```
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

## VolumeNotifier（RMS 回報）

`VolumeNotifier` 是 audio pipeline 的輸出端，將即時 RMS 音量送往主 App。

### 資料流

```
AudioProcessorActor.processRMS()  (1s 一次 per-track，actor executor)
    │
    │  rmsSIMD(from: buffer) → vDSP_measqv
    │  取樣 RMS (0~1)
    │
    │  normalized = rms * userVolume
    │  if trackType == .app → lastAppRMS = normalized
    │  else                 → lastMicRMS = normalized
    │
    ▼
VolumeNotifier.updateVolume(app: appRMS?)    ← app 軌更新
VolumeNotifier.updateVolume(mic: micRMS?)    ← mic 軌更新（獨立間隔）
    │
    ▼
SocketClient.shared.flushVolumeBatch() → _sendBatch([])
    │   payload: { type: "logbatch", entries: [], appVol, micVol }
    ▼
liveAPP SocketServer → LiveVolumeModel.updateVolumes(mic:micVol, app:appVol)
    → @Published UI（不持久化，避免 socket 延遲覆蓋正確值）
```

### 設計要點

- **無內部狀態**：actor 負責維護 `lastAppRMS`/`lastMicRMS`，`VolumeNotifier` 僅為 relay
- **無重複 throttle**：依賴 actor 的 `rmsInterval=1.0`，移除 VolumNotifier 自身的 `minInterval`
- **Per-track 獨立計時器**：app/mic 各自有 `lastAppRMSUpdateTime` / `lastMicRMSUpdateTime`，避免單一計時器讓另一個音軌被餓死
- **Per-channel 增量更新**：`updateVolume(app: Float? = nil, mic: Float? = nil)` 只更新有變化的 channel，不再用舊值覆蓋另一軌的 UserDefaults
- **音量數據過期淘汰**：`SocketClient` 追蹤 `latestVolumeTimestamp`，`_sendBatch` 發現距上次更新 > 2.5s 時將 volume 送 0，避免 RMS 停止後（離開音頻頁、音源中斷）最後數值永久殘留在 logbatch 中
- **單一傳輸路徑**：一律走 E-Socket `logbatch`，移除 `Darwin Notification`（易掉通知）和 `audioLive` 消息（永不發送）
- **僅 `onAudioPage=true` 時作用**：`processRMS` 第一道 guard 檢查 `onAudioPage`

### 修改歷程

| 改前 | 改後 | 理由 |
|------|------|------|
| `pendingAppVolume`/`pendingMicVolume` + `lastSendTime` + `minInterval=0.1` | 無狀態 | actor 的 1s throttle 已足夠，雙軌共享 pending 值造成另一軌值最多舊 1s |
| sideload→socket；其他→Darwin Notification | 一律 socket `logbatch` | Darwin Notification fire-and-forget，背景易掉；`audioLive` 從未使用 |
| `updateVolume(volume:track:)` 帶 track | `updateVolume(app:mic:)` 帶兩軌值 | actor 保管 lastRMS，發送時兩軌最新值同步 |
| `rmsInterval=1.0` 與 `minInterval=0.1` 疊加 | 僅 `rmsInterval=1.0` | 簡化，消除重複節流 |
| 單一 `lastRMSUpdateTime` | per-track `lastAppRMSUpdateTime` / `lastMicRMSUpdateTime` | 避免一個音軌長期佔用計時器，另一軌值永遠不更新 |
| `updateVolume(app: Float, mic: Float)` 強制雙參數 | `updateVolume(app: Float?, mic: Float?)` 選擇性更新 | `processRMS` 只送有變化的 channel，不再用另一軌的舊值（含初始 0）覆蓋 UserDefaults |
| volume 值無過期機制，RMS 停止後最後數值永久殘留 | `latestVolumeTimestamp` + 2.5s 過期淘汰 | 離開音頻頁或音源中斷後 volume 正確歸零，不卡在舊值 |

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

---

## HaishinKit encoder 管線改進

### 問題：背景暫停後 encoder 無法恢復

當使用者切到 GPU 密集型遊戲時，iOS 會暫停 broadcast extension 的執行。恢復前景後：

1. `NetworkMonitor` timer 大量落後，一次觸發時 `interval > 10s`
2. 但 encoder stall 累積計數器 (`videoStallCount`) 在暫停期間未被歸零
3. 原本的機制需要 3 次連續 monitor 觸發（每次 ~1s）才會重建 encoder session
4. 被暫停後 timer 只觸發一次，永遠湊不滿 3 次

結果：encoder session 一直處於失效狀態，`videoInputFrames > 0` 但 `frameCount == 0`，畫面凍結直到下次正常 stall 檢測。

### 修正

**檔案：** `F:\HaishinKit.swift\RTMPHaishinKit\Sources\RTMP\RTMPStream.swift`

```swift
// 改前：gap > 1.5s 只做 log
if interval > 1.5 {
    await connection?.log(.warn, "publish status gap", ...)
}

// 改後：gap > 3.0s 且 encoder 無進度 → 跳過累積，立即重建
if interval > 3.0, readyState == .publishing, videoInputFrames == 0 || frameCount == 0 {
    await restartVideoPipeline(reason: "suspended gap of ...")
    restartedVideoPipeline = true
}
```

### 預期改善

| 場景 | 改前 | 改後 |
|------|------|------|
| 玩遊戲時 extension 被暫停 → 恢復 | encoder session 失效，需等 3 次 monitor 觸發（永遠等不到） | gap > 3s 立即重建 encoder |
| 短暫卡頓 (< 3s) | 正常 stall 累積 3 次後重啟 | 不影響（3s 閾值不觸發） |
| 前景暫停後恢復 | 等待累積，約 3s | gap 偵測到 >3s 立即跳過累積流程 |
