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
| `commandBufferTimeout` | 1.0s | GPU command buffer 逾時 → 回 nil + `handleMetalFailure` |
| `CommandCompletionState` | NSLock | 保證 completion vs watchdog 恰好一次 resume |
| `outputPool` maxPoolSize | 10 | CVPixelBuffer 重用池上限，溢位 evict 最舊 |

#### GPU completion 順序與 PTS 排序

Swift actor 只保證同步片段互斥，不保證整個 `async` 方法從頭到尾不可重入。`FrameProcessorActor.processFrame()` 在 `await rotator.rotateAsync()` 等待 Metal completion 時，actor executor 可以讓下一個 frame 進入，於是多個 `MTLCommandBuffer` 可能同時 in-flight。

現場 FLV 曾觀察到真正 H.264 NALU tag 的 DTS 有倒退與重複，例如 timestamp 反覆回到 `0/10/33/66ms` 附近。這可能來自 GPU completion out-of-order，也可能來自更底層的 RTMP/FLV timestamp 基準更新或 probe 取樣方式；不能只憑這個現象直接判定上游一定需要丟幀 gate。

目前不在 `VideoFrameProcessor.process()` 加 `NSLock` hot-path gate：

- 30/60fps 熱路徑上每幀同步鎖雖然絕對成本不高，但會增加不必要的保護層與掉幀策略。
- 如果底層 MediaMixer/VideoToolbox/RTMP pipeline 已按 PTS 排序或保證單調輸出，外層 gate 只是重複保護。
- 若後續證實確有 out-of-order append，優先在底層 timestamp/queue 邊界做 PTS 單調檢查、排序或丟棄晚到幀，而不是在最上游用 lock 擋所有並行。

#### 為何沒有 in-flight semaphore

早期版本有 `DispatchSemaphore(value:2)` 限制 GPU 同時 in-flight 數量，但分析後發現多餘：

- `rotateAsync` 內 `withCheckedContinuation` 負責等待目前 command 完成。
- 若底層已按 PTS 單調輸出，限制 GPU in-flight 不是必要條件。
- Watchdog (1s) 已處理 GPU hang 的罕見狀況，不需要額外 semaphore 做 timeout

目前管線維持：actor → rotateAsync → continuation → completion → append。若要加入順序保護，應先確認底層沒有既有 PTS 排序，再選擇最靠近 mux/encoder 的單調邊界處理。

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
    │  applyGainIfSafe(sampleBuffer)            audioEngine?.process(sampleBuffer, track:)
    │     │                                           │
    │     │  Int16/Float32 PCM + gain > 1 才改寫      │  Int16→Float→DSP→Float→Int16
    │     │                                           │
    │     ▼                                           ▼
    │  processRMS()                            processRMS()
    │     │                                       │
    │     │  rmsSIMD() → vDSP_measqv               │  rmsSIMD() → 更新 lastRMS
    │     │  更新 lastAppRMS/lastMicRMS             │  VolumeNotifier.updateVolume()
    │     │  VolumeNotifier.updateVolume()          │
    │     ▼                                       ▼
    │  mediaMixer.append()                    mediaMixer.append()
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
    │  AudioProcessorActor 已序列化呼叫；AudioPreProcessor 不再額外加 processLock
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
return to AudioProcessorActor.enqueue()
```

### AudioEngine 直送 MediaMixer

```
AudioProcessorActor.enqueue()
    │
    ├── audioEngine.process(sampleBuffer, track:)   ← 同步原地 DSP
    ├── processRMS(sampleBuffer, trackType:)
    └── await mediaMixer.append(sampleBuffer, track:)
```

AudioEngine 現在是純 DSP wrapper，不再建立 `AsyncStream<ProcessedAudio>` 或 detached consumer。HaishinKit 底層已經有 `MediaMixer` / `AudioMixerByMultiTrack` 的非同步處理層，上層再包一層 stream 會把延遲、背壓和 flush 節奏變複雜。

同理，`AudioPreProcessor.process()` 不再額外使用 `processLock`。外層 `AudioProcessorActor` 已經序列化進入 DSP 的呼叫；DSP 內部鎖會在 100Hz audio hot path 增加同步成本，且容易讓後續維護者誤以為可以從 actor 外多執行緒重入。

### 音訊斷續根因與修正（2026-08）

#### 歷史根因（五層疊加）

| # | 問題 | 位置 |
|---|------|------|
| ① | **producer 與 consumer 共用同一 actor executor**：`enqueue`（含同步 DSP）與舊 `streamTask` 同在 `AudioProcessorActor` 上，DSP 慢時 consumer 被凍結、反之亦然 → 節奏耦合 | `AudioProcess.swift` |
| ② | **AsyncStream unbounded**：consumer 落後時 producer 無限 yield → 延遲無限堆積，MediaMixer 一空就一次消化大量 → 節奏暴衝 | `AudioNoiseFix.swift` |
| ③ | **MediaMixer 是共用 actor**：video/audio append 全串列排隊，video 慢時 audio 被卡 | `MediaMixer.swift` |
| ④ | **`AudioMixerTrack.resample()` 同步 convert 迴圈**：`repeat { convert } while .haveData` 在 ring buffer 積壓時一次轉完所有幀，同步霸佔 MediaMixer actor → 阻塞所有 append | `AudioMixerTrack.swift` |
| ⑤ | **`AudioRingBuffer` 的 `skip` 補 silence**：producer 節奏亂 → PTS 缺口 → 插 silence → 聽覺斷續 | `AudioRingBuffer.swift` |

聽覺斷續來自 ⑤，但觸發源是 ①②③④。**使用者也確認：`useOriginal`（不經 DSP/Metal）也斷續 → 底層 ③④⑤ 是共用瓶頸**，兩條路徑最終都進 `mediaMixer.append` → `AudioMixerByMultiTrack` → `AudioMixerTrack.resample()`。

#### 現行修正

**Extension 端（`AudioProcess.swift`、`AudioNoiseFix.swift`）**：

- 移除 AudioEngine / useOriginal 上層 AsyncStream，`AudioProcessorActor.enqueue` 直接做同步 DSP / gain / RMS 後 `await mediaMixer.append`。
- 移除 `AudioPreProcessor.processLock`，保留 `AudioProcessorActor` 作為單一序列化邊界。

**底層（`AudioMixerTrack.swift`）**：

- `resample()` 改為動態 inputBlock（`min(inNumberFrames, ringBuffer.counts)`）+ **無界 `while .haveData` 迴圈**。原 `repeat { convert } while .haveData` 在 actor 上執行會霸佔 MediaMixer；方案 C 將 resample 移到專用 queue 後，無界迴圈只佔自己的 queue，積壓時一次消化全部才能追上延遲。

#### 已移除的過渡方案

過渡期曾嘗試：

```
AudioEngine.startStream() → AsyncStream<ProcessedAudio>
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

後續判定這是過度設計，因為 HaishinKit 底層已經有必要的 queue / stream 邊界；上層 stream 只會新增一層背壓語意。

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

**目標：** useOriginal 模式（`isOringinAudio`）應盡量接近 passthrough。只有使用者明確設定 boost，且來源格式確認安全時，才允許改動原始音訊資料。

| 問題 | 原因 | 修正 |
|------|------|------|
| **use-after-free（斷序主因，增益 >1.0 時）** | `applyGain` → `pcmBufferToCMSampleBuffer` 用 `kCFAllocatorNull` 包住區域變數 `AVAudioPCMBuffer` 的記憶體建 CMBlockBuffer；函式返回後記憶體釋放，append 非同步讀到已釋放資料 | `applyGain` 改**原地增益**：直接對原始 block buffer 做 int16→float→增益→寫回，不重建 CMSampleBuffer（AudioProcess.swift:346-369） |
| 增益誤套到其他 PCM 格式 | `applyGain` 直接把 block buffer bind 成 `Int16`，若 ReplayKit 給 Float32 或其他 PCM 格式，gain >1 時會用錯格式改壞原始音訊 | `applyGain` 先檢查 ASBD：signed Int16 走 Int16→Float→gain→clip→Int16；Float32 走原地 gain→clip；其他格式 passthrough 並節流 log |
| 預設配置斷序 | useOriginal 路徑 producer（enqueue）與 consumer（`mediaMixer.append`）未解耦 | 初期嘗試 AsyncStream + detached consumer 解耦，後續判定為**過度設計而移除**——見下方「上層 AsyncStream 移除」 |
| 0.0 死碼預設（誤判） | `SharedDefaults.group?.double(forKey:) ?? 1.0` 未設定時回傳 0.0（`?? 1.0` 死碼，memory 261）；0.0 被當 `micGain` → 麥克風靜音 | 改用 `(object(forKey:) as? Double) ?? 1.0`（SampleHandler.swift 4 處 event handler + Event.swift 4 處 config 載入） |

**關鍵決策 — 維持 boost-only + 格式安全語意**：`applyGain` 的 guard 是 `finite && clamp(1...30) && gain > 1.0 && supported PCM`。目前支援 signed Int16 與 Float32；不能用 `abs(gain-1.0) > 0.001`，也不能未檢查 ASBD 就 bind `Int16`；useOriginal 管線的預設行為必須是不改動未知格式的原始音訊。

**診斷 log**：`[AudioGain] <track> apply format:<signedInt16|float32> gain:<value> samples:<count>` 會每軌最多 5 秒輸出一次；不支援格式時輸出 `skip unsupportedPCM rawGain:<value>`。這用來確認 useOriginal boost 實際走哪個 PCM 分支。

#### 上層 AsyncStream 移除（過度設計修正，2026-08-21）

**問題：** AudioEngine（DSP 路徑）與 useOriginal 各自包了一層 AsyncStream + `Task.detached` consumer，疊在 HaishinKit 已有的非同步機制之上：

```
我們的 AsyncStream ─→ MediaMixer actor ─→ AudioMixerByMultiTrack queue ─→ resample
    ─→ HaishinKit 自己的 audioIO.output AsyncStream ─→ encoder
```

**底層調查（TwhomeGH/HaishinKitFixSwfit）：** HaishinKit 已完整處理非同步——`mediaMixer.append` 只是 `AudioMixerByMultiTrack.append` 的 `queue.async`（非阻塞，AudioMixerByMultiTrack.swift:138-146）；resample 在該 queue 上輸出乾淨的 1024-sample 塊、時間戳正確推進；輸出走自己的 `audioIO.output` AsyncStream。**我們上層那層 AsyncStream 是冗餘的第三層。**

**修正：** 全部移除，`AudioProcessorActor.enqueue` 直接 `await mediaMixer.append`：

```swift
func enqueue(_ sampleBuffer: CMSampleBuffer, trackType: AudioTrackType, originalTime: CMSampleTimingInfo) async {
    guard await mediaMixer.isRunning else { return }
    if useOriginal {
        let processed = applyGain(sampleBuffer, trackType: trackType)
        processRMS(processed, trackType: trackType, originalTime: originalTime)
        await mediaMixer.append(processed, track: trackType.rawValue)
    } else {
        audioEngine?.process(sampleBuffer, track: trackType)   // 原地 DSP
        processRMS(sampleBuffer, trackType: trackType, originalTime: originalTime)
        await mediaMixer.append(sampleBuffer, track: trackType.rawValue)
    }
}
```

- `AudioEngine` 簡化成**純 DSP wrapper**：移除 `startStream`/`streamContinuation`/`finish`/`ProcessedAudio`，`process()` 只剩原地 DSP（降噪/回音/AGC/增益）。
- `AudioProcessorActor` 移除 `streamTask`/`originalStreamTask`/`originalContinuation`/`setupAudioStream`/`setupOriginalStream`。
- 背壓由 HaishinKit 的 AudioRingBuffer 處理；wire 實測 76s 零掉幀，無退化。
- **video 管線無此問題**：video 只有「每幀 `Task {}` 橋接 + FrameProcessorActor + 直接 append」，無 AsyncStream（`processSampleBuffer` 是 sync，Task 橋接為必要）。

**`updateAudioState` 接線（原死碼啟用）：** DSP 設定（enableNoiseFix/enableEchoFix/...）原本只在 AudioEngine init 套用一次。新增 `SocketClient.onAudioConfigChanged` callback，`applyRTMP` 的 `updateAudio` 後觸發 → SampleHandler → `audioProcessor.updateAudioState(...)`，直播中改設定即時生效。

**行為對照：**

| 情境 | 改前 | 改後 |
|------|------|------|
| useOriginal + 增益 >1.0 | 每幀 CMSampleBuffer 重建 + use-after-free → 音訊毀損 | 原地 vDSP（µs 級），無分配無釋放問題 |
| 音訊上層 | 2 個 AsyncStream（AudioEngine + useOriginal）+ HaishinKit 的 1 個 | 移除我們兩個，只剩 HaishinKit 原生那層 |
| DSP 設定直播中變更 | 死碼，不生效 | `onAudioConfigChanged` 接線，即時生效 |
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
| A3 | `actor` → `processRMS()` | sync method | actor → RMS/volume telemetry |
| A4 | `actor` → `mediaMixer.append()` | HaishinKit API | actor → encoder |

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

**檔案：** HaishinKit repo `TwhomeGH/HaishinKitFixSwfit` — `RTMPHaishinKit/Sources/RTMP/RTMPStream.swift`

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


---

## AHealth（音訊管線健康 telemetry，2026-09）

### 動機

VHealth 只能看視訊。分析 `log-39`（2026-09-11）後發現：useOriginal 原音路徑在整個 session 幀數完美（85.93 幀/秒、PTS 20 分鐘只漂 10ms、零 frame loss、零 stall），但使用者仍聽到斷音。這證明**斷音是 content-level**（1024-sample 封包內部的樣本被丟掉或補靜音），現有 log 完全看不到。AHealth 把下游 mixer 的丟樣本計數也送上圖表。

### 資料流

```
SampleHandler.logAudioHealthIfNeeded()  (每幀，ReplayKit queue)
    ├── 上游：per-track frameCount / 幀間 PTS gap
    └── 每秒：Task → await mediaMixer.audioPipelineDiagnostics()   (HaishinKit)
              → finalizeAudioHealthSample()  (com.replykit.ahealth serial queue)
                  ├── 累計計數 → delta（align drop / skip / overflow / underrun）
                  ├── 累積 5s 窗口 → min/avg/max 彙總
                  ├── SocketClient.sendAudioHealth(...)  → liveAPP AudioHealthModel
                  └── sendlog(title: "[AHealth]", ...)
```

### 指標

| 層 | 指標 | 來源 |
|----|------|------|
| 上游 | app/mic inputFPS（min/avg/max） | `SampleHandler` per-track 幀計數 |
| 上游 | 幀間 PTS gap max (ms) | per-track PTS delta |
| 上游 | RMS | `SocketClient.latestAppVolume/latestMicVolume` |
| 下游 | `alignDroppedPerSec` | `AudioRingBuffer.align()` 丟棄樣本 |
| 下游 | `alignInsertedPerSec` | `align()` 補靜音 |
| 下游 | `skipInsertedPerSec` | `append()` PTS gap 補靜音 |
| 下游 | `overflowDroppedPerSec` | ring buffer 溢位丟樣本 |
| 下游 | `resampleNoDataPerSec` | `resample()` 該次 append 完全無產出 |
| 下游 | `mixerOutputFPS` | `AudioMixerByMultiTrack.mix()` 成功次數 |

### HaishinKit 依賴

下游計數需要 HaishinKit 提供 `MediaMixer.audioPipelineDiagnostics()`（公開型別 `AudioPipelineDiagnostics`）。變更已套用到 HaishinKit repo `TwhomeGH/HaishinKitFixSwfit`（`HaishinKit/Sources/Mixer/`：新增 `AudioPipelineDiagnostics.swift`，並在 `AudioRingBuffer` / `AudioMixerTrack` / `AudioMixerByMultiTrack` / `AudioCaptureUnit` / `AudioMixer` / `MediaMixer` 加入計數與公開 API）。

### 診斷邏輯

- `align-drop`：`AudioRingBuffer.align()` 丟棄非 main track 樣本。這是目前最可疑的 content-level 斷音來源（雙軌 PTS 基座差被當成 desync）。
- `source-gap`：PTS 缺口讓 `append()` 用 `skip` 補靜音，或幀間 gap > 100ms。
- `underrun`：`resample()` 某次 append 完全沒產出，代表 ring buffer 來不及給完整 1024。


### HaishinKit 音訊混音設計修正（2026-09-11）

在 HaishinKit repo `TwhomeGH/HaishinKitFixSwfit`（`HaishinKit/Sources/Mixer/`）：

| # | 問題 | 修正 |
|---|------|------|
| 1 | ~~`align()` 單位不一致~~ **（誤判，已更正）**：`align` 作用在 `AudioMixerByMultiTrack.buffers[track]`，該緩衝區是以 `outputFormat` 建立的，其 `sampleTime` 與 mixer playhead 同為 output 單位 → **沒有單位不一致** | 已回退，不加換算 |
| 2 | `align()` 每次全量硬丟/硬補，來源抖動會造成每幀微修正（細碎斷音） | 加 `alignDeadband`（256 samples ≈ 5.8ms）：門檻內視為量測抖動，不修正 |
| 3 | `mainTrack` 同時決定時鐘、輸出格式、免對齊軌；main=mic 會強制 mono | `AudioMixerSettings` 新增 `outputFormatTrack`（預設 `UInt8.max` = 沿用 `mainTrack`）；ReplyKit `configureAudio()` 改設 `mainTrack=1`（mic 時鐘）+ `outputFormatTrack=0`（app 立體聲格式） |
| 4 | `append()` 的 PTS gap 用 `skip` 補靜音，且 `skip` 一律在佇列最前面消費，會把已緩衝樣本整體往後推 | 改為 `appendZeros()` 把 gap 的 0 樣本寫進尾端（正確位置） |
| 5 | `diagnosticsSnapshot()` 用 `queue.sync` 會阻塞 MediaMixer actor | 改為 queue 上維護、鎖保護的快取，讀取端只上鎖不排隊 |
| 6 | **stereo→mono 只取左聲道**：`AudioMixerTrack.audioConverter` 對輸出 mono 設 `channelMap = [0]`，只取輸入第 0 聲道，右聲道被丟掉（非 L+R 平均） | 輸入聲道 > 輸出聲道時**不設 `channelMap`**，讓 `downmix` 依 channel layout 做 L+R 平均；mono→stereo 仍用 `[0,0]` 複製、stereo→stereo 用 `[0,1]` 直通 |

**AHealth 新增欄位**：`alignFirePerSec`（align 實際動手次數/秒）、`alignDiffMaxSamples`（窗口內最大偏差，input 樣本）。狀態新增 `align-churn`；`[AHealth]` log 也帶上 `alignFire` / `alignDiff`，走 E-Socket 回報以便後續分析。


### AHealth 介面

#### `[AHealth]` log（走 E-Socket）

```
[AHealth] <status> win:5s app:[min avg max] mic:[min avg max] gapMax:<ms>ms alignDrop:<n> alignIns:<n> alignFire:<n> alignDiff:<n> skip:<n> noData:<n> mixOut:<n>/s rms[app:<f> mic:<f>]
```

- 每秒累積、每 5s 彙總一筆（與 `[VHealth]` 同節奏）。
- 與 `[VHealth]` 一樣：非 sideload 且不在日誌頁時會被 `sendlog` 跳過。

#### socket payload（`audioHealth`）

| 欄位 | 型別 | 意義 |
|------|------|------|
| `status` | String | 見下方狀態表 |
| `appInputFPSMin/Avg/Max` | Double | app 軌 input FPS 窗口 min/avg/max |
| `micInputFPSMin/Avg/Max` | Double | mic 軌同上 |
| `appGapMaxMs` | Double | app/mic 幀間 PTS gap 最大值（ms） |
| `alignDroppedPerSec` | Double | align 丟棄樣本/秒 |
| `alignInsertedPerSec` | Double | align 補靜音樣本/秒 |
| `alignFirePerSec` | Double | align 實際動手次數/秒 |
| `alignDiffMaxSamples` | Double | 窗口內最大 align 偏差（input 樣本） |
| `skipInsertedPerSec` | Double | PTS gap 補 0 樣本/秒 |
| `overflowDroppedPerSec` | Double | ring buffer 溢位丟樣本/秒 |
| `resampleNoDataPerSec` | Double | resample underrun 次/秒 |
| `mixerOutputFPS` | Double | 混音輸出區塊/秒 |
| `appRMS` / `micRMS` | Double | 音量 RMS 平均 |
| `outChannels` | Int | 混音輸出聲道數（1=mono, 2=stereo） |
| `outCh0RMS` / `outCh1RMS` | Double | 混音輸出左/右聲道 RMS（判斷是否被 downmix 成 mono、哪一側有聲） |

#### 狀態

| 值 | 意義 |
|----|------|
| `healthy` | 一切正常 |
| `input-idle` | app/mic 都幾乎沒輸入 |
| `align-churn` | align 幾乎每秒都在動手（content-level 斷音主訊號） |
| `align-drop` | align 有丟棄樣本 |
| `buffer-overflow` | ring buffer 溢位 |
| `underrun` | resample 有 append 無產出 |
| `source-gap` | PTS gap 補靜音 / gap > 100ms |

#### 圖表（liveAPP「Audio Pipeline」）

- Input FPS：app / mic 兩條折線。
- 丟樣本：align drop / skip / underrun / align fire 四條。
- Mixer out：輸出區塊/秒。
- 文字：狀態、align fire/diff、align inserted/overflow、range、PTS gap、RMS。

#### 資料流（程式碼）

```
SampleHandler.logAudioHealthIfNeeded()  (每幀)
  → 每秒 Task → await mediaMixer.audioPipelineDiagnostics()  (HaishinKit)
    → SampleHandler.finalizeAudioHealthSample()  (com.replykit.ahealth serial queue)
      → SocketClient.sendAudioHealth(...)  → liveAPP Socket "audioHealth" → AudioHealthModel
      → sendlog(title: "[AHealth]", ...)
```
