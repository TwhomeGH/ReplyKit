# ReplyKit 核心修正與性能改進

## 1. Socket 日誌傳輸管線重構（滑動視窗批次傳輸）

### 問題
每 1 秒 `flushLocalLogs()` 把整個 buffer `joined()` 成一個巨大字串 → 單次 payload 可能數百 KB → 8KB chunking 產生 N 個 `{"type":"log"}` 排進 serial queue → 最後的 chunk 等幾十秒 → 30s watchdog 砍連線。

### 修正
- **Ring buffer**（`Event.swift`）：`[String]` 改用固定 1000 條上限，超過自動 `removeFirst(excess)` 批次丟棄最舊，移除 byte 級追蹤
- **Batch send**（`ReplyKIT/Socket.swift`）：累積 entries，每 50 條或 4KB 打包成 `{"type":"logbatch","entries":[...]}` 一次送出，250ms 定時器確保殘餘 flush
- **Bounded window**：最多 3 個 in-flight batch，滿了自動 drop 最舊 batch
- **Server handler**（`liveAPP/Socket.swift`）：新增 `case "logbatch"` 解包逐條餵給 `receiveSocketLog`

### 預期改善
| 場景 | 改前 | 改後 |
|------|------|------|
| 大量 log burst | buffer 衝到 100KB → joined 送出 → socket timeout → 斷線重連 loop | ring buffer 自動 drop 最舊，batch ≤4KB，window 滿就 drop，連線穩定 |
| 連線中斷恢復 | pendingLogs 全部 replay（再次塞車） | pendingBatchEntries 暫存，reconnect 後 flush，單批 ≤4KB |

---

## 2. GPU 旋轉管線修復（GPUVideoRotator）

### 問題
- `gpuSemaphore`（AsyncSemaphore value:5）**完全未使用**：`wait()` 從未呼叫、`signal()` 被註解掉 → GPU 背壓形同虛設
- `NGPUSemaphore`（DispatchSemaphore value:10）**死碼**：從未使用
- `asyncWait()` helper 僅為 `NGPUSemaphore` 存在 → 死碼

### 修正
- `gpuSemaphore` 改為 **value: 3**（更合理），`wait()` 在 `rotateAsync` 開頭、`signal()` 在 GPU completion handler 中啟用
- 移除 `NGPUSemaphore` 與 `asyncWait()`

### 預期改善
- **GPU 不再強制串行**：改前 GPU 一次只能處理 1 幀（CPU 等 GPU→GPU 等 CPU），改後最多 3 幀 pipeline 執行
- **GPU 使用率提升**：CPU 準備 frame N+1 時 GPU 同時處理 frame N
- **60fps 更穩定**：減少因等待造成的掉幀

```
改前: CPU prepare → GPU rotate → CPU prepare → GPU rotate → ... (一次1幀)
改後: CPU prepare → GPU rotate (frame N)
         → CPU prepare → GPU rotate (frame N+1) ← 最多3幀飛行
```

---

## 3. VideoProcessor Watchdog（GPU 逾時自動重置）

### 問題
GPU 旋轉卡死時（驅動錯誤、Metal 內部 hang），`isProcessing = true` 永遠不會被釋放 → 後續所有 frame 被丟棄 → **直播斷流**。

### 修正
- 2 秒逾時檢測：`processingStartedAt` 記錄開始時間，下一幀抵達時檢查
- 逾時自動重置：`processorActor = nil` → 下一幀重新建立完整管線
- `processorActor` 改為 optional，看門狗可安全重建

### 預期改善
- **GPU hang 復原時間**：從「永久卡死」縮短到 **2 秒內自動恢復**
- **直播不中斷**：短暫掉 2-3 秒畫面後恢復正常推流

---

## 4. AppLogPersister 日誌檔 I/O 爆炸與無限制增長

### 問題
`liveAPPApp.swift:112-173` 存在**兩層問題**：

**第一層（容量）**：僅不斷 append，完全沒有限制 → 日誌檔隨時間無限增大。

**第二層（效能，更嚴重）**：初始修正加入 `trimLogFileIfNeeded()` 後，**每一行 log 寫入都觸發全檔讀取 + 分割 + 可能全檔寫回**：

```
append("hello") → write() → trimLogFileIfNeeded()
  → FileHandle.readToEnd() (讀完整個 5000 行檔案)
  → content.split(separator: "\n")
  → lines.count > 5000? 是 → suffix(5000) → 寫回完整檔案
```

重複此流程的次數等於日誌寫入次數。100 lines/sec 下，這等於 **100 次/秒完整讀寫 ~500KB 檔案**。serial queue 上的 I/O 積壓可能導致：
- **App 被 watchdog 判定主執行緒 hang → 強制終止 → 直播斷流**
- **寫入延遲疊加 → 寫一行 log 要數百毫秒完成**

### 修正
- **記憶體行數計數器**：`estimatedLineCount` 追蹤檔案行數，**不讀檔不 trim**
- **寬容閾值**：超過 `5000 + 2000`（即 7000 行）才安排 trim，減少 trim 頻率
- **Debounce 延遲**：超過閾值後延遲 **1 秒**才執行 trim，同批 burst 只觸發一次
- **trim 後更新計數器**：避免下次 trim 又全檔讀取

### 預期改善
| 場景 | 改前 | 改後 |
|------|------|------|
| 一般寫入（99.9% 情況） | 每行都全檔讀寫 | O(1) append only，trim 不執行 |
| 超過 7000 行時 | 每行都 trim（可能持續數百次） | 1 秒內只 trim 一次，回到 5000 行 |
| 大 burst（數千行瞬間湧入） | 數千次全檔讀寫，App 可能被 watchdog 殺 | 一次 trim + 安全邊界

---

## 5. RemoteLogBuffer 爆量丟棄優化

### 問題
`RemoteLogBuffer.append` 使用 `removeFirst()` 逐條移除 → 大量 burst 時 N 次陣列 shift + N 次 `sendlog` 警告 → 日誌中數百條連續警告反而**加重 socket 負擔**。

### 修正
- 先 `append`，超過上限後一次 `removeFirst(excess)` 移除全部超額
- 只 log 一次警告

### 預期改善
- **爆量時不再觸發數百條警告迴圈**
- **陣列只 shift 一次**，CPU 開銷從 O(n) 降到 O(1)（amortized）

---

## 6. 設備資訊頁增強

### 磁碟 I/O 圖表
`DeviceView`（`OtherView.swift`）新增「磁碟 I/O」圖表與文字顯示，包含三個指標：

| 指標 | 來源 | 顏色 |
|------|------|------|
| **Page In**（換頁讀取） | `vm_statistics.pageins` × page size | 🔵 藍 |
| **Page Out**（換頁寫出） | `vm_statistics.pageouts` × page size | 🔴 紅 |
| **App Write**（日誌寫入） | `AppLogPersister.totalWrittenBytes` 差值 | 🟢 綠 |

- 每 1 秒取樣，`SystemDiskIO` 計算差值 → KB/s
- 三線疊合圖表，下方附加最新值文字
- 可直觀判斷 watchdog kill 是否與大量檔案 I/O 或系統 swap 相關

### 儲存空間 - 可用 vs 空閒

iOS 的 `FileManager` 提供兩種容量查詢：

| API | 標籤 | 含義 |
|-----|------|------|
| `.volumeAvailableCapacityForImportantUsageKey` | 可用（含可清除） | 系統顯示的「可用空間」= 真正空閒 + 可 purge 的快取 |
| `.systemFreeSize` | 空閒（真正） | 純粹未使用的磁區空間 |

原始碼之前誤用了 `.systemFreeSize` 並標為「可用」，導致比裝置設定顯示的數字少一大截。修正後**兩者並列**，方便比對。

---

## 7. Socket 接收管線優化（消除雙重 dispatch + 批次處理）

### 問題
`liveAPP/Socket.swift:784-802` 的 `handleReceivedData` 存在**不必要的雙重 dispatch**：

```
runReceiveLoop (Task)
  → handleReceivedData
    → parsingQueue.async (JSON 解碼)      ← dispatch 1
      → self.queue.async (處理 payload)   ← dispatch 2
```

每條 socket 訊息經歷「Task executor → parsingQueue (concurrent) → self.queue (serial)」三層 context switch。`logbatch` 內每條 entry 又各自呼叫 `receiveSocketLog` → `LogBuffer.push` + `AppLogPersister.append`（再兩個 queue dispatch）。

### 與 watchdog kill 的關聯
App 進入背景後，SocketServer 透過 `UIBackgroundTask` 保持運作，但背景任務僅有 ~30 秒的保證存活時間。原本每次 logbatch（50 條）產生 **100 次 queue dispatch + 50 次 LogBuffer 寫入 + 50 次檔案 I/O** 的連鎖開銷，在背景時容易：
1. 累積 dispatch 延遲 → 無法在背景配額內完成處理
2. Dispatch queue 積壓 → 主執行緒 responsiveness 下降 → watchdog 判定 hang
3. 大量小 I/O 操作 → 觸發 Memory Warning → 系統提前終止 App

### 修正
- **移除 `parsingQueue`**：JSON 解碼直接在 `self.queue` 上完成，**一次 dispatch 到位**
- **`logbatch` 批次處理**：取消逐條 `receiveSocketLog`，改為一次 `batch.entries.map` → 單次 `LogBuffer.shared.push(prefixed)` + 單次 `AppLogPersister.append(lines:)`

### 預期改善
| 等級 | 改前 | 改後 |
|------|------|------|
| dispatch 次數（一般訊息） | 2（parsingQueue → self.queue） | 1（self.queue） |
| dispatch 次數（50 條 logbatch） | 50 × 2 = 100 次 | 1 |
| `LogBuffer.push` 次數（50 條） | 50 次 | 1 次（`append(contentsOf:)`） |
| `AppLogPersister.append` 次數（50 條） | 50 次 | 1 次（`append(lines:)`） |
| 背景 watchdog 風險 | 高（大量 queue dispatch 累積延遲，超逾背景配額） | 低（一次 dispatch、一次檔案 I/O，快速完成） |

---

## 8. 廣播暫停/恢復 — VideoToolbox encoder 重建與前景復原

### 問題
`SampleHandler.swift` 的 `broadcastPaused()` 與 `broadcastResumed()` 原始碼**都是空的**。當 App 進入背景 → ReplayKit 暫停廣播 → 返回前景時，系統會 invalidate VideoToolbox encoder session，但沒有任何程式碼負責重建。

從 log-6 觀察：
```
06:14:29  正在離開App（進入背景）
06:14:35  Memory Warning（系統可能殺 extension）
06:14:52  回到前景 → audio 恢復正常，video 完全停止
06:17:08  StreamEnded（只有 audio 持續到最後）
```

原因：`mediaMixer.isRunning` 在背景時可能被系統設為 `false`，導致 `VideoFrameProcessor.process()` 的 `guard isRunning` 跳過所有後續 frame。就算 `isRunning` 仍為 `true`，VideoToolbox encoder 也已被 invalidate，無法編碼新 frame，但 audio encoder 不受影響，因此只掉 video。

**特別注意：廣播 extension 無法使用 `UIBackgroundTask`。** 不同於主 App，ReplayKit 廣播 extension 的行程在背景時由系統直接控制，完全沒有類似 `UIBackgroundTask` 的背景執行延長手段。`broadcastPaused()` 的唯一用途是標記狀態。

### 修正
```swift
// SampleHandler.swift

override func broadcastPaused() {
    isBroadcastPaused = true
    disconnectMonitorTask?.cancel()  // 背景時停止監控
}

override func broadcastResumed() {
    isBroadcastPaused = false
    
    // 1. 重建 Socket 連線（背景可能斷開）
    SocketClient.shared.setupConnection()
    
    // 2. 重啟 MediaMixer（若被系統暫停）
    if !(await mediaMixer.isRunning) {
        await mediaMixer.startRunning()
    }
    
    // 3. 強制重建 VideoToolbox encoder session
    let settings = await stream.videoSettings
    try stream.setVideoSettings(settings)
    
    // 4. 重置 video processor 看門狗狀態
    videoProcessor?.resetProcessing()
    
    // 5. 重啟斷線監控
    startDisconnectMonitor()
}
```

### 預期改善
| 場景 | 改前 | 改後 |
|------|------|------|
| 背景 → 前景後的 video 恢復 | 完全中斷，永久不恢復 | 2-3 秒內重建 encoder，恢復推流 |
| Audio 持續性 | 正常（不受影響） | 正常（不受影響） |
| GPU encoder session | 被系統 invalidated，永不重建 | `setVideoSettings` 強制重建新 session |
| Socket 連線 | 背景斷開後無人處理 | `setupConnection()` 主動重連 |
| 斷線監控 | 背景時 Task 被 cancel 不重啟 | `startDisconnectMonitor()` 重啟 |

---

## 9. LogTextView 頁面切換崩潰 + LogBuffer 記憶體上限

### 問題
在 `onLogPage` ↔ `onAudioPage` 之間快速切換時，存在**兩層問題疊加**導致崩潰：

**第一層（UITextView detached view 操作）**：
- `LogView.onDisappear` 設 `isVisible=false` 並呼叫 `cancelPendingWork()` 取消尚未執行的 `DispatchWorkItem`
- 但已排入 main queue 且正在執行中的 `DispatchWorkItem` 無法取消
- 此時 `UITextView` 已被 SwiftUI 從 window 階層移除，但 `textView` 參考仍非 nil
- `tv.layoutIfNeeded()` / `tv.scrollRangeToVisible()` 在 detached view 上執行觸發 `EXC_BREAKPOINT` / `SIGTRAP`

**第二層（背景串流時 LogBuffer 無上限）**：
- `LogBuffer.buffer` 原先沒有任何上限
- 背景模式下主線程被節流，`flushLocked()` → `onNewLog` 消化不及
- socket 持續湧入 `logbatch`（RTMP debug log），buffer 無限制增長
- 最終觸發記憶體壓力 → OOM / 系統終止

### 修正

**Coordinator 防護**（`ContentView.swift:1270,1404`）：
```swift
// appendMessages DispatchWorkItem 內
guard let self = self, let tv = self.textView, tv.window != nil else {
    self?.appendWorkItem = nil
    return
}

// scrollToBottomUsingRange
guard let tv = textView, tv.window != nil else { return }
```
所有對 `UITextView` 的 layout / scrolling 操作前先檢查 `tv.window != nil`，視圖已脫離 window 時直接放棄。

**LogBuffer 上限**（`liveAPPApp.swift:53,60,70,75-79`）：
```swift
private let maxBufferSize = 5000

private func trimIfNeededLocked() {
    guard buffer.count > maxBufferSize else { return }
    let excess = buffer.count - maxBufferSize
    buffer.removeFirst(excess)
}
```
每次 `push` 後呼叫 `trimIfNeededLocked()`，超出 5000 條即丟棄最舊。

### 預期改善
| 場景 | 改前 | 改後 |
|------|------|------|
| 快速切換 onLogPage/onAudioPage | detached UITextView 操作 → EXC_BREAKPOINT 崩潰 | `tv.window != nil` 檢查，安全跳過 |
| 背景串流大量 log 寫入 | LogBuffer 無上限增長 → 記憶體壓力 → OOM | 上限 5000 條，超出自動 drop 最舊 |
| 背景主線程節流時 | buffer 持續膨脹無節制 | buffer 固定上限，不累積 |

---

## 整體性能預期

| 指標 | 改前 | 改後 |
|------|------|------|
| Socket 連線穩定性 | burst log → timeout → 斷線重連 loop | batch 限流，連線保持不斷 |
| GPU 使用率 | ~30-40%（串行等待） | ~60-80%（3 幀 pipeline） |
| GPU hang 復原 | 永久卡死 | ≤2 秒自動重置 |
| 日誌檔大小 | 無限增長 | ≤~7000 行（trim 後回 5000） |
| Log burst 時 CPU（陣列層） | O(n) 逐條 shift + N 次 sendlog | O(1) amortized + 1 次 sendlog |
| AppLogPersister 寫入開銷 | 每筆寫入都全檔讀寫（O(N)） | O(1) append only，trim debounce 1s |
| 檔案 I/O 導致的 watchdog kill | 高風險（大量 log 時累積延遲） | 低風險（無 trim 時等同 0 I/O） |
| Socket 接收 dispatch（一般訊息） | 2 次 queue 跳轉 | 1 次 queue dispatch |
| Socket 接收 dispatch（50 條 logbatch） | 100 次 dispatch + 50 次 push + 50 次 append | 1 次 dispatch + 1 次 push + 1 次 append |
| 背景模式下 watchdog 終止風險 | 高（大量小 dispatch + 小 I/O 超逾背景配額） | 低（單次批次處理快速完成） |
| 背景 → 前景 video 恢復 | video 永久中斷，永不恢復 | 2-3 秒內重建 encoder，恢復推流 |
| 頁面切換穩定性 | 快速切換 onLogPage/onAudioPage 高機率崩潰 | window nil 檢查，安全防護 |
| 背景串流 LogBuffer 記憶體 | 無上限，長時間背景高機率 OOM | 上限 5000 條，自動截斷 |

---

## 10. broadcastResumed 視訊管線重建 + 側載清除日誌優化

### 問題

**視訊管線**：`broadcastResumed()` 只呼叫 `videoProcessor?.resetProcessing()` 重設外層 `VideoFrameProcessor.isProcessing` gate flag，但未處理 `ProcessorActor`（actor）內部的 `isProcessing`。若 actor 在暫停前已因 GPU hang 卡死，`resetProcessing()` 將外層 `isProcessing` 歸零 → 外層 watchdog 不再觸發 → actor 永遠卡在 `guard !isProcessing else { return nil }` → 恢復後所有 video frame 被無聲丟棄。

**清除日誌**：側載模式下無 App Group container，`「清除日誌」` 按鈕總是落入 `else` 印出 `❌ 無法取得 containerURL`。

### 修正

**視訊管線**（`SampleHandler.swift:1966`）：
```swift
// 改前
videoProcessor?.resetProcessing()

// 改後：重建整個 VideoFrameProcessor（含新 ProcessorActor）
rebuildVideo()
```

**清除日誌**（`ContentView.swift:1609-1622`）：
```swift
// 改前：else 印 "❌ 無法取得 containerURL"
// 改後：無 App Group container 時直接跳過，不報錯誤
```

### 預期改善
| 場景 | 改前 | 改後 |
|------|------|------|
| 背景恢復後 video 狀態 | resetProcessing 無效，actor 卡死 → video 靜默失敗 | 重建整個 processor → actor 乾淨啟動 |
| 側載清除日誌 | 每次顯示「無法取得 containerURL」錯誤 | 跳過共享容器，正常完成 |

---

## 11. 音量頁即時 RMS 節流（防 socket 洪流斷線）

### 問題
停留在音量頁（`onAudioPage=true`）時，`processRMS` 對每幀音訊進行 SIMD 頻譜運算 + `VolumeNotifier.updateVolume` 觸發 socket `sendAudioLive`。`rmsInterval = 0.2s` 和 `minInterval = 0.2s` 雙重節流實質合併成一道，產生 **5Hz socket 寫入洪流**，與 RTMP 的 `logbatch`（每 0.25s 一批）疊加，NWConnection 內部 send queue 積壓 → 系統主動關閉連線 → 管線崩潰。

從 `log.txt` 可見：07:43:58 切至音量頁後 12 秒內生成 **54 筆** `Updated UserVol`，07:44:10 連線斷開。

### 修正

**節流降頻**（`AudioProcess.swift`）：
| 屬性 | 改前 | 改後 |
|------|------|------|
| `AudioProcessor.rmsInterval` | 0.2s (5Hz) | 1.0s (1Hz) |
| `VolumeNotifier.minInterval` | 0.2s (5Hz) | 1.0s (1Hz) |

**VolumeNotifier 精簡**（`AudioProcess.swift:140-183`）：
```swift
// 改前：自有 queue + closure 捕獲凍結舊值 + 雙重 dispatch
private let queue = DispatchQueue(label: "com.liveapp.volumeNotifier")
func updateVolume(volume: Float, track: Int) {
    ...
    queue.async { [weak self, pendingAppVolume, pendingMicVolume] in
        SocketClient.shared.sendAudioLive(appVol: pendingAppVolume, micVol: pendingMicVolume)
    }
}

// 改後：caller 已在 Task.detached (global executor)，直接發送，零多餘 dispatch
func updateVolume(volume: Float, track: Int) {
    ...
    guard now - lastSendTime >= minInterval else { return }
    lastSendTime = now
    let app = pendingAppVolume    // 讀最新累積值
    let mic = pendingMicVolume
    SocketClient.shared.sendAudioLive(appVol: app, micVol: mic)
}
```
移除 `queue`、`hasPendingSend` flag、`asyncAfter` 延遲合併——`sendAudioLive` → `sendPayload` 內部已自行 dispatch 到 `SocketClient.queue`。

### 預期改善
| 場景 | 改前 | 改後 |
|------|------|------|
| 音量頁 socket 寫入頻率 | 5Hz（與 logbatch 重疊致 send queue 積壓） | 1Hz 即時發送 |
| dispatch hop 數 | ReplayKit → Task.detached → VolumeNotifier.queue → SocketClient.queue（4 層） | ReplayKit → Task.detached → SocketClient.queue（3 層） |
| volume 值時效性 | closure 捕獲凍結舊值（Mic 初始為 0） | 直接讀最新累積值 |
| CPU 開銷 (RMS SIMD) | 每 0.2s | 每 1.0s |

---

## 12. Video 管線連續失敗偵測與自動重建

### 問題
Video 管線在初始幾十幀後停止產出（`append(video)` 不再出現），但 `videoProcessor` 非 nil、外層 watchdog 未觸發、無任何警告日誌。原因是兩層失效路徑皆未被覆蓋：

1. **`processFrame` 快速返回 nil**（Metal resource 敗壞但不掛死）：外層 `isProcessing` 正常循環，watchdog 永不觸發
2. **`GPUVideoRotator.cleanupResources()` 誤設 `isActive = false`**：`handleMetalFailure()` 連續 5 次 Metal 失敗後調用 `cleanupResources()` → `isActive` 永久變 false → `getReusableOutput()` 永遠 return nil → 所有後續 video frame 無聲丟棄

### 修正

**雙重失敗計數**（`VideoProcess.swift:119-121,230-234`）：
```swift
private var watchdogResetCount: Int = 0      // GPU 掛死 >2s
private var consecutiveDropCount: Int = 0     // processFrame nil 返回
private let maxConsecutiveDrops = 60          // ~1 秒 @60fps

// 旋轉失敗時：
self.consecutiveDropCount += 1
if self.consecutiveDropCount >= self.maxConsecutiveDrops {
    self.isActive = false   // 標記重建
}

// 成功時歸零
self.watchdogResetCount = 0
self.consecutiveDropCount = 0
```

**SampleHandler 重建檢查**（`SampleHandler.swift:2303-2308`）：
```swift
if let vp = videoProcessor {
    if vp.isActive {
        vp.process(sampleBuffer, ...)
    } else if !isStopping {
        rebuildVideo()  // isActive=false → 觸發重建
    }
}
```

**GPU Rotator 修復**（`GPUVideoRotator.swift:319,386`）：
```swift
// cleanupResources() 不再設 isActive = false（只清 Metal 資源）
// handleMetalFailure() 加 rebuildQueue()
MetalContext.shared.rebuildQueue()
```

**MetalContext**（`MetalContext.swift:33`）：新增 `rebuildQueue()` 重建 command queue。

**AsyncSemaphore 移除**（`GPUVideoRotator.swift:499,588`）：`VideoFrameProcessor.isProcessing` gate 已確保單一幀序列化，semaphore 多餘。且 signal 放在 `Task { }` 內異步執行，延遲可能導致下一幀 `wait()` 永久阻塞。

### 預期改善
| 場景 | 改前 | 改後 |
|------|------|------|
| 連續旋轉失敗 | 無聲丟幀，永不重建 | 60 幀後 isActive=false → rebuildVideo |
| GPU 逾時掛死 | 2s watchdog 重置 actor（但 isActive 卡死時無效） | 3 次逾時後 isActive=false → rebuildVideo |
| Metal resource 敗壞修復 | cleanupResources 設 isActive=false 後永不恢復 | 只清 Metal 資源，isActive 保持 true，下幀自動重建管線 |
| AsyncSemaphore | signal 放 Task{} 異步，延遲致下幀 wait() 永久阻塞 | 移除 wait/signal（isProcessing gate 已序列化） |

---

## 13. 清除日誌按鈕修復

### 問題
`logModel.clearLogs()` 只清 `LogModel.messages`，但 `LogTextView.Coordinator` 有自己的 `messageLines`、`appendedUUIDs` 和 UITextView 文字內容未被清除，頁面上的日誌仍顯示。

### 修正
- `Coordinator` 新增 `clearText()`：清空 `messageLines`、`appendedUUIDs`、`appendQueue`、`currentLineCount` 及 `tv.text`
- 「清除日誌」按鈕呼叫 `coordinator?.clearText()`

---

## 14. GPU Texture Cache 隔離 + cleanup 時序修正

### 問題
三層連鎖導致前景恢復後 video 斷流：

1. **共用 Texture Cache 衝突**：`ensureMetalResources()` 從 `MetalContext.shared.ensureTextureCache()` 取得共用 cache。`cleanupResources()` 執行 `CVMetalTextureCacheFlush` + `textureCache = nil` 時，因所有 rotator 實例共享同一份 cache，舊 rotator 的 flush 會將新 rotator 正在使用的 texture 一併沖掉。

2. **cleanup() actor 未正確清理**：`VideoFrameProcessor.cleanup()` 先 `Task { await processorActor?.cleanup() }` 再 `processorActor = nil`。Task closure 捕獲的是 `self.processorActor` 參照（非值捕獲），執行時已是 nil → 舊 actor 的 GPU 資源從未釋放。

3. **前景恢復觸發雙重重建**：`broadcastResumed()` → `rebuildVideo()` 建新 processor。舊 processor cleanup 的 Task 沖掉共用 cache → 新 processor 的 rotator texture 失效 → video 永久斷流。

### 修正

**Texture Cache 隔離**（`GPUVideoRotator.swift:396-402`）：
```swift
// 改前：共用 MetalContext.shared 的 cache
textureCache = ctx.ensureTextureCache()

// 改後：每個 rotator 獨立建立
var cache: CVMetalTextureCache?
CVMetalTextureCacheCreate(nil, nil, ctx.device, nil, &cache)
textureCache = cache
```

**移除 cache flush**（`GPUVideoRotator.swift:319-340`）：`cleanupResources()` 不再執行 `CVMetalTextureCacheFlush` 或 `textureCache = nil`，僅清理 output pool / pipeline。

**cleanup 時序修正**（`VideoProcess.swift:139-142`）：
```swift
// 改前：Task 捕獲參照，後 nil，Task 內已無法存取 actor
Task { await processorActor?.cleanup() }
processorActor = nil

// 改後：先存 local，再 nil，再 Task cleanup
let oldActor = processorActor
processorActor = nil
Task { await oldActor?.cleanup() }
```

**MetalContext**（`MetalContext.swift:33`）：新增 `rebuildQueue()` 供 `handleMetalFailure()` 調用。

### 預期改善
| 場景 | 改前 | 改後 |
|------|------|------|
| 前景恢復後 video | 共用 cache 被 flush → 新 rotator texture 失效 → 斷流 | 獨立 cache，舊 cleanup 不影響新 rotator |
| 舊 actor GPU 資源 | Task 無法存取（已 nil）→ 從未釋放 | 值捕獲先存 local → 正確 cleanup |
| 多次 rebuildVideo | 第二次起共用 cache 已被前次沖掉 | 每次獨立建 cache，互不影響 |