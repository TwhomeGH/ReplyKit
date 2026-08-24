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
- **時間戳**：`makeFallbackSampleBuffer` 用 `CMSampleBufferCreateReadyWithImageBuffer` 重打**目前幀的 PTS**（`presentationTimeStamp: pts`、`decodeTimeStamp: .invalid`）。絕不能用舊幀 PTS，否則 `RTMPTimestamp.update` 偵測 `value <= updatedAt` 走 invalid sequence 重置 → Non-monotonous DTS → 碼率爆衝假象。
- **duration 優先序**（2026-08-21）：`originalTime.duration`（sample buffer 自己的值）→ `measuredInterval`（EMA 量測）→ 1/60（最後極端退路）。`FrameProcessorActor.trackFrameInterval` 用 EMA（alpha 0.2）追蹤輸入幀的 PTS delta；freeze 期間 ReplayKit 幀仍以真實幀率送達，量測值自動適應 30/60fps，避免 freeze 期間每幀少報 16.67ms（60fps 假設）造成 timeline 漂移。`cleanup()` 時重置量測狀態，避免跨 rebuild 沿用舊間隔。
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

統一由 `ensureVideoProcessor(_:timing:)` / `ensureAudioProcessor(_:trackType:timing:)` 負責「確保處理器存在且可用」：

```
SampleHandler 診斷 (每 1500 幀)
    │  vp:Y / vp:INACTIVE / vp:N
    ▼
ensureVideoProcessor()
    ├── vp 存在且 isActive → vp.process(frame)          ← happy path，直接處理
    └── 否則（nil 或 INACTIVE）：
          ├── guard processorsInitialized && !isStopping
          ├── guard lastTimestamp > lastlogTime + 1s   ← rate-limit 每秒至多一次
          ├── log 原因（進程不存在 / GPU 連續逾時）
          └── rebuildVideo()
                ├── videoProcessor = nil
                ├── VideoFrameProcessor(mediaMixer, sendlog)  ← 全新 FrameProcessorActor
                │     └── GPU rotator 全新初始化 → pipeline 重新編譯
                └── 下一幀開始走新管線
```

audio 端 `ensureAudioProcessor` 邏輯相同，但**沒有 inactive 分支** — `AudioProcessor.isActive` 是 `let isActive = true` 恆真（audio pipe 無 GPU 逾時機制），「存在但 inactive」在 audio 是死碼，已移除。

#### 改進（2026-08-21）：收斂重建路徑 + 移除 rebuild 風暴

先前的兩段 if/else（video 與 audio 各一份）有三個問題，本次一併修正：

| 問題 | 舊行為 | 新行為 |
|------|--------|--------|
| rebuild 風暴 | video 的「存在但 inactive」分支**每幀**呼叫 `rebuildVideo()`（GPU 持續逾時時 60fps → 每秒 60 次 new + cleanup） | 所有 recovery 路徑統一 rate-limit **每秒至多一次**，首次偵測仍立即重建 |
| 行為不一致 | video：inactive 無 rate-limit；nil 有 1s rate-limit，兩條路徑不對稱 | 兩條路徑共用同一 rate-limit |
| audio 死碼 | `AudioProcessor.isActive` 恆 `true`，`else if !isStopping` 分支永遠不可達 | 移除死碼分支，audio 只剩「nil → rate-limited rebuild」一條 recovery 路徑 |

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
         （bufferingPolicy: .bufferingNewest(8)，有界背壓）
    │
    ▼
streamTask = Task.detached { [weak self] in        ← detached，脫離 actor executor
    for await item in stream {
        guard await mediaMixer.isRunning else { continue }
        await processRMS(item.buffer, trackType:, originalTime:)
        await mediaMixer.append(item.buffer, track:)
    }
}
```

### 音訊斷續根因與修正（2026-08）

#### 根因（五層疊加）

| # | 問題 | 位置 |
|---|------|------|
| ① | **producer 與 consumer 共用同一 actor executor**：`enqueue`（含同步 DSP）與 `streamTask` 同在 `AudioProcessorActor` 上，DSP 慢時 consumer 被凍結、反之亦然 → 節奏耦合 | `AudioProcess.swift` |
| ② | **AsyncStream unbounded**：consumer 落後時 producer 無限 yield → 延遲無限堆積，MediaMixer 一空就一次消化大量 → 節奏暴衝 | `AudioNoiseFix.swift` |
| ③ | **MediaMixer 是共用 actor**：video/audio append 全串列排隊，video 慢時 audio 被卡 | `MediaMixer.swift` |
| ④ | **`AudioMixerTrack.resample()` 同步 convert 迴圈**：`repeat { convert } while .haveData` 在 ring buffer 積壓時一次轉完所有幀，同步霸佔 MediaMixer actor → 阻塞所有 append | `AudioMixerTrack.swift` |
| ⑤ | **`AudioRingBuffer` 的 `skip` 補 silence**：producer 節奏亂 → PTS 缺口 → 插 silence → 聽覺斷續 | `AudioRingBuffer.swift` |

聽覺斷續來自 ⑤，但觸發源是 ①②③④。**使用者也確認：`useOriginal`（不經 DSP/Metal）也斷續 → 底層 ③④⑤ 是共用瓶頸**，兩條路徑最終都進 `mediaMixer.append` → `AudioMixerByMultiTrack` → `AudioMixerTrack.resample()`。

#### 修正

**Extension 端（`AudioProcess.swift`、`AudioNoiseFix.swift`）**：

- `streamTask` 改 `Task.detached`：consumer 脫離 `AudioProcessorActor` executor，producer 的同步 DSP 與 consumer 的 `mediaMixer.append` 真正並行。
- `AudioEngine.startStream()` 改用 `.bufferingNewest(8)`：有界背壓（~184ms @44.1k），consumer 落後時丟最舊而非無限堆積。

**底層（`AudioMixerTrack.swift`）**：

- `resample()` 改為動態 inputBlock（`min(inNumberFrames, ringBuffer.counts)`）+ **無界 `while .haveData` 迴圈**。原 `repeat { convert } while .haveData` 在 actor 上執行會霸佔 MediaMixer；方案 C 將 resample 移到專用 queue 後，無界迴圈只佔自己的 queue，積壓時一次消化全部才能追上延遲。

#### 效能參數調整（2026-08）

| 檔案 | 常數 | 原值 | 新值 | 理由 |
|------|------|------|------|------|
| `AudioMixerTrack.swift` | `kAudioMixerTrack_frameCapacity` | 1024 | **1024（維持）** | ⚠️ **不可調大**（見下） |
| `AudioNode.swift` | `OutputNode.buffer` frameCapacity | 1024 | 1024 | 與 mixer frameCapacity 同步引用（internal 常數） |
| `AudioCodecSettings.swift` | AAC `inputBufferCounts` | 6 | **12** | 6×1024≈139ms 偏小，抖動大時 converter 來不及消化而丟幀；12≈278ms 給 encoder 呼吸空間 |
| `AudioCodecSettings.swift` | AAC `outputBufferCounts` | 1 | **2** | 避免 convert 迴圈 removeFirst/release 頻繁重分配 |
| `AudioRingBuffer.swift` | `bufferCounts` | 16 | **24** | 371ms→557ms 緩衝，吸收 producer 節奏抖動，減少 skip 補 silence |
| `AudioMixerTrack.swift` | resample 渲染上限 | 無界 →（曾加 4/16）→ **無界** | 實測 audioInputFrames=audioFrames=43-45/s 完全吃得動，上限是不必要限制 |
| `AudioCodec.swift` | convert 上限 | 無界 →（曾加 8）→ **無界** | 同上，encoder 端也跟得上 |

**注意**：`audioTime.advanced(outputBuffer.frameLength)` 依實際輸出幀數推進（原硬編碼 1024），`AudioCodec` 端維持 `mFramesPerPacket`（AAC=1024）推進 — 兩者各自對應正確。`frameCapacity` 是 AVAudioConverter 的 framesPerPacket，非固定常數。

#### ⚠️ `kAudioMixerTrack_frameCapacity` 不可調大（2026-08-13 事故）

曾嘗試調大到 4096（減少 convert/AudioUnitRender 呼叫次數），**導致整條音訊管線停擺**：

- **機制**：`AudioMixerTrack.resample()` 的 `AVAudioConverter.convert(to: error:withInputFrom:)` 輸入 callback 請求的 `inNumberFrames` **等於 outputBuffer.frameCapacity**。ReplayKit 每幀輸入 1024 samples，ring buffer 每次只有一幀。frameCapacity=4096 時 converter 請求 4096 > ringBuffer.counts → 回 `.noDataNow`（AudioMixerTrack.swift:103）→ **不產出任何輸出**。
- **症狀**：`publish throughput audioInputFrames=0 audioFrames=0 audioBytes=0`，但 extension 端 `[Audio流水]` 正常計數、影片 36fps 正常。斷點精準落在 `AudioMixerByMultiTrack` 產出前。
- **結論**：frameCapacity 必須等於上游單幀輸入數（1024），它同時決定 `OutputNode.render` 的 AudioUnitRender 幀數，改動需同步 AudioNode。此參數是「對齊約束」而非「效能旋鈕」。

#### ✅ 自動配置修正（2026-08-13 二次修復）

官方文檔兩處關鍵約束：
- `convert(to:from:)`（一次性）：output.frameCapacity ≥ input.frameLength
- `convert(to:error:withInputFrom:)`（block 驅動）：converter "attempts to fill the buffer to its capacity"，但 **AVAudioConverterInputBlock 允許回傳少於請求的幀數**（設定 frameLength = 實際幀數），converter 消費後視需要再請求。

**修正**：inputBlock 改為動態提供 ring buffer 現有全部幀數（`min(inNumberFrames, ringBuffer.counts)`），不再「不足請求量就 `.noDataNow` 停擺」。這樣：
- `outputBuffer.frameCapacity` 不需對齊上游單幀大小 — 任何輸入幀數都能自動消化
- `audioTime` 依實際輸出幀數（`outputBuffer.frameLength`）推進，而非硬編碼 1024
- `AudioMixerByMultiTrack.mix()` 與 `OutputNode.render` 都用 `frameLength` 自動適應

套用檔案：`AudioMixerTrack.resample()`、`AudioCodec.append()`（相同模式）。

#### ✅ 方案 C：音訊處理移到專用 queue（治本，2026-08-13 三次修復）

**問題**：即便修正 frameCapacity 與 inputBlock，`AudioMixerByMultiTrack` 的整條音訊處理鏈（append→convert→mix→AudioUnitRender）仍在 **MediaMixer actor** 上執行。convert 迴圈與 AudioUnitRender 同步霸佔 actor，video/audio append 互搶，audio 積壓 → 斷續。

**修正**（`AudioMixerByMultiTrack.swift`）：
- 新增專用 serial queue（`com.haishinkit.HaishinKit.AudioMixerByMultiTrack`）
- 兩個 `append` 改 `queue.async`：MediaMixer actor 的 append **立即返回**，convert/AudioUnitRender 在專用 queue 執行，不再佔用 actor
- `settings` 改 `NSLock` 保護：getter/setter 用 lock，setter 排 `queue.async` 執行 `applySettings`（重建 outputFormat）；內部統一走 `_settings`（queue 上無鎖）
- `inputFormats` getter 用 lock 保護
- `track(for:)`/delegate 用 `_settings`，queue 內一致存取

**thread-safety**：
- `inputRenderCallback`（AudioUnit 實時執行緒）讀 `buffers` 字典 — 既有並行行為，方案 C 不新增
- `delegate` 的 `continutation?.yield` 從 queue 呼叫 — AsyncStream yield thread-safe
- `mix()` 的 `settings.isMuted` 走 lock getter — setter 的 lock 不等待 queue，無死鎖

#### ✅ 移除渲染上限（2026-08-13 四次修復）

`AudioMixerTrack.resample()` 與 `AudioCodec.append()` 原加的 `maxRendersPerAppend` / `maxConvertsPerAppend` 上限**完全移除**，恢復 `while .haveData` 無界迴圈。

- **理由**：實測 `audioInputFrames=audioFrames=43-45/s`（44.1kHz/1024 ≈ 43.07 幀/秒）— 完美即時節奏，input/encoder 產出完全一致，**完全吃得動**，上限是不必要的限制。
- **方案 C 後**：resample 在專用 queue 執行，無界迴圈只霸佔自己的 queue，不影響 video/actor。積壓時一次消化全部才能追上延遲、避免 ring buffer 滿掉幀。
- 若上游真的極端暴衝，無界迴圈在 queue 上執行有自然背壓，不會阻塞 MediaMixer actor。

#### ⚠️ 電磁音事故 — inputBlock 不可餵部分幀（2026-08-13 五次修復）

**問題**：曾把 inputBlock 改為動態提供 `min(inNumberFrames, ringBuffer.counts)`（部分幀餵入），聲稱「任何輸入幀數都能自動消化」。**結果出現電磁音/爆音（壞塊）**。

**機制**：`AVAudioConverterInputBlock` 雖允許回傳少於請求的幀數，但**下游 AudioUnit render 與 AAC 編碼都要求固定 1024 對齊**：

```
AudioMixerTrack 產出 frameLength=512（非對齊，因部分幀餵入）
  → AudioMixerByMultiTrack.track(didOutput:) → mix(numberOfFrames: 512)
    → AudioUnitRender(512) → inputRenderCallback → AudioRingBuffer.render
      → 剩餘 512 vs 請求 1024 → 樣本錯位 → 電磁音/爆音
```

AAC 端同理：AAC 需要固定 1024 幀 PCM 才產出一個 packet，部分幀餵入讓 converter 輸出錯位。

**修正**：恢復「只餵完整幀」邏輯 — `inNumberFrames <= ringBuffer.counts` 才 render 完整幀，不足回 `.noDataNow`（資料留在 ring buffer，累積到 1024 後下次 append 消化）。維持 1024 對齊。

- `AudioMixerTrack.resample()` → `inNumberFrames <= ringBuffer.counts` 檢查
- `AudioCodec.append()` → `isDataAvailable(inNumberFrames)` 檢查

**與 frameCapacity 事故的區別**：frameCapacity=4096 事故是「converter 請求 4096 > ring buffer 1024 → 永遠 .noDataNow → 0 輸出」；現在 frameCapacity=1024，converter 請求 1024，累積夠了就給完整 1024 — 不會停擺也不會錯位。

**結論**：inputBlock 必須餵完整幀維持 1024 對齊。「自動消化任何幀數」的目標已由「frameCapacity=1024 + ring buffer 累積 + 無界迴圈」達成，不需動態部分幀。

#### 修正後行為

| 情境 | 修正前 | 修正後 |
|------|--------|--------|
| DSP 慢（producer 卡） | consumer 被凍結，buffer 無限堆積 | consumer 獨立 executor（`Task.detached`），持續消化；積壓時 `.bufferingNewest(8)` 丟最舊 |
| MediaMixer 被 video 佔用 | audio append 排隊 → PTS gap → silence | audio 處理在專用 queue，MediaMixer actor 只排隊立即返回，video/audio 互不阻塞 |
| ring buffer 積壓 | resample 霸佔 MediaMixer actor，一次轉完所有幀 | 專用 queue 上無界消化，一次追上積壓，不影響 actor |
| 幀大小變化 | frameCapacity 固定 1024，輸入不同則停擺 | inputBlock 只餵完整幀（不足 `.noDataNow` 累積），維持 1024 對齊 |
| 時間戳 | 硬編碼 1024 推進 | `audioTime.advanced(outputBuffer.frameLength)` 依實際輸出幀數 |

#### originAudio（useOriginal）路徑修正（2026-08-21）

**目標：** useOriginal 模式（`isOringinAudio`）原本與 DSP 路徑不同步——gain 用危險的 CMSampleBuffer 重建往返、append 在 actor 上 inline，且音量讀取有 0.0 死碼預設。修正三件套：

| 問題 | 原因 | 修正 |
|------|------|------|
| **use-after-free（斷序主因，增益 >1.0 時）** | `applyGain` → `pcmBufferToCMSampleBuffer` 用 `kCFAllocatorNull` 包住區域變數 `AVAudioPCMBuffer` 的記憶體建 CMBlockBuffer；函式返回後記憶體釋放，append 非同步讀到已釋放資料 | `applyGain` 改**原地增益**：直接對原始 block buffer 做 int16→float→增益→寫回，不重建 CMSampleBuffer（AudioProcess.swift:346-369） |
| 增益形同虛設 / Float32 閃退 | `toPCMBuffer` 強制 `int16ChannelData!`（Float32 會 crash）；`applyGainPCM` 用 `floatChannelData`（Int16 buffer 為 nil → gain 永遠 no-op） | 移除 `toPCMBuffer`/`applyGainPCM`/`pcmBufferToCMSampleBuffer` 死碼，原地增益保證真正生效 |
| 預設配置斷序 | useOriginal 路徑 producer（enqueue）與 consumer（`mediaMixer.append`）**未解耦**——append 慢時阻塞 actor 音訊節奏；DSP 路徑已有 AsyncStream + `Task.detached` | useOriginal 比照 DSP 路徑：enqueue 只做原地增益 + `yield`，consumer 用 `Task.detached` 做 `processRMS` + `mediaMixer.append`（AudioProcess.swift:311-323） |
| 0.0 死碼預設（誤判） | `SharedDefaults.group?.double(forKey:) ?? 1.0` 未設定時回傳 0.0（`?? 1.0` 死碼，memory 261）；0.0 被當 `micGain` → 麥克風靜音 | 改用 `(object(forKey:) as? Double) ?? 1.0`（SampleHandler.swift 4 處 event handler + Event.swift 4 處 config 載入） |

**關鍵決策 — 維持 boost-only 語意**：`applyGain` 的 guard 是 `gain > 1.0`，不能用 `abs(gain-1.0) > 0.001`——否則 0.0（死碼預設）會被當成合法衰減 → 音訊消音。`addVolume` 是放大倍率，只有 >1.0 才需要處理。

**行為對照：**

| 情境 | 改前 | 改後 |
|------|------|------|
| useOriginal + 增益 >1.0 | 每幀 CMSampleBuffer 重建 + use-after-free → 音訊毀損 | 原地 vDSP（µs 級），無分配無釋放問題 |
| useOriginal 預設 1.0 | append 在 actor 上 inline，慢時斷序 | producer/consumer 解耦，與 DSP 路徑一致 |
| 音量 key 未設定 | 0.0 誤判 → micGain=0 靜音 | `?? 1.0` 真正生效 |

---

## RTMP 時間戳基準跳變修正（2026-08-13）

### 問題

`RTMPTimestamp.update`（RTMPHaishinKit）只處理「倒退」（`value.seconds <= updatedAt`），**不處理向前大跳**。基準跳變時：

| 情境 | 改前行為 | 後果 |
|------|----------|------|
| 倒退（15000→13000） | 回傳 0 + **重置基準** | wire timestamp 跳回 0，後續從新基準累積 → Non-monotonous DTS |
| 向前大跳（13000→15000） | **2,000,000ms 巨大 delta 上 wire** | 下游 ffmpeg 誤判 gap/seek → 畫面凍結、音訊中斷、AV 自動修正 → **突然斷流** |

RTMP type-1/type-2 的 timestamp 是**相對 delta 累積**，下游絕對時間 = delta 累積和。基準跳變（AudioMixerTrack 重建、ReplayKit PTS 切換）時送巨大 delta 或重置基準，都讓下游時間軸錯亂。

### 修正（`RTMPTimestamp.swift`）

統一 clamp：`delta < 0 || delta > maxDelta(2000ms)` 時，用上一次正常 delta（`lastNormalDelta`）取代：

```swift
if timedelta < 0 || timedelta > Self.maxDelta {
    logger.warn("RTMPTimestamp jump: \(source) ...")
    timedelta = lastNormalDelta   // 維持平滑，不重置基準
}
```

- `maxDelta = 2000ms`：單一 delta 上限，涵蓋最低幀率（0.5fps idle），正常直播幀間距 < 100ms
- `lastNormalDelta`：上一次正常 delta，基準跳變時維持 wire 平滑
- **不重置基準**：`updatedAt` 仍更新為新值，跳變後第一個 clamp delta 是「假的」，之後恢復正常 — 只在跳變當下平滑

### 設計要點

- **雙保險不需要**：`AudioMixerByMultiTrack` 已有自動重新對齊機制 — `setupAudioNodes` 重置 `sampleTime = 0`，下次 mainTrack `track(didOutput:)` 因 `sampleTime == 0` 重新設 `sampleTime`/`anchor`，`mix()` 用新基準。anchor 不需手動重置。
- **clamp 而非回傳 0**：回傳 0 會讓 wire 時間戳停滯一幀；clamp 到 `lastNormalDelta` 讓時間戳平滑前進，下游完全察覺不到跳變。

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
    │  ensureVideoProcessor() 偵測到 vp 非 active
    │  (rate-limit: 每秒至多一次 rebuild，避免每幀重建風暴)
    ▼
rebuildVideo()
    │
    ├── 舊 VideoFrameProcessor cleanup
    └── 新的 VideoFrameProcessor (全新 GPU rotator)
```

`onPermanentFailure` 是 `FrameProcessorActor` 的 `let onPermanentFailure: (@Sendable () -> Void)?`，在建構時透過 `nonisolated func setPermanentFailureHandler()` 設定。

AudioProcessor 的 `isActive` 固定為 `true`（audio pipe 無永久失敗路徑，純供 diagnostics 顯示 "Y"），因此 audio 端不存在「存在但 inactive」分支（原為死碼，2026-08-21 移除），只有「nil → rate-limited rebuild」。

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

### SampleHandler resume 重建改為有條件（2026-08-21）

**問題：** `broadcastResumed()` 原本每次 resume 都無條件執行整套重建——`setVideoSettings(同樣的 settings)` 強迫 VideoToolbox 重建 encoder session + `rebuildVideo()` 拆掉整個 video processor（新 FrameProcessorActor + GPU rotator + Metal pipeline 重編譯）。健康情況（encoder 沒壞）下這是白做工，每次前景切回都造成一次推流 reconfig 閃斷。

**修正（`ReplyKIT/SampleHandler.swift`）：**

- `broadcastPaused()` 記錄 `pausedAt`；resume 計算暫停時長。
- **Encoder 重建**只在暫停 ≥3s（`broadcastPauseRecoveryThreshold`）時才強制執行——長暫停才可能被系統 suspend 造成 encoder stall；短暫切換完全不打斷推流。
- **`rebuildVideo()`** 只在 `videoProcessor == nil || !isActive` 時執行；失效情況另有 `ensureVideoProcessor` 每秒自動補救。
- 移除頂部 guard 與內層重複的 `!isReconnecting`（重連中由 reconnect 成功 handler 負責 restart mixer）。

**行為對照：**

| 場景 | 改前 | 改後 |
|------|------|------|
| 快速前景/背景切換（<3s） | 每次重建 encoder + video processor → 推流閃斷 | 不重建，推流完全不中斷 |
| 長時間暫停（≥3s，可能被 suspend） | 重建（正常） | 保留 encoder 重建保險 + processor 失效才重建 |
