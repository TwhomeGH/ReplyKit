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

## 8. Socket 連線改為按需連線（On-Demand），移除永久連線 + 自動重連

### 問題

主 App 被 iOS 殺後台後，SocketServer 停止運行，但 Extension 的 `SocketClient` 仍在背景執行無限重連迴圈：指數退避（2s→30s）→ 斷路器 5 次後 60s 冷卻 → 再試。每次重連消耗 CPU 與 Mach port 配額，永遠不會成功。

### 修正

| 移除項目 | 替代方案 |
|---------|---------|
| `retry()`、`reconnectDelay()`、`maxReconnectAttempts` | 無 — 連線斷開即放棄，不自動重連 |
| 斷路器（`circuitBreaker*`） | 無 — 沒有重連就不需要斷路器 |
| 狀態機（`SocketState` enum） | 無 — 簡化為連線存在/不存在 |
| 心跳（`startHearbeat`、`stopHeartbeat`、50s timer） | ❌ 已移除 — 按需連線不再需要發送心跳保活 |
| `onSocketReady` / `handleSocketReconnected()` | 無 — 不再有 reconnect callback |
| `pendingLogs` + `flushPendingLogs()` | 無 — reconnect 不存在，layer 不再需要 |
| `sendReconnectStatus` | 無 — PiP 不再顯示 socket 重連狀態 |

**新流程**：每個需要 socket 的操作獨立管理自己的連線生命周期。`connect()` 是冪等的（已有連線時返回），`_closeConnection()` 在每個回應處理完後自動呼叫。

### 預期改善

| 場景 | 改前 | 改後 |
|------|------|------|
| 主 App 背景被殺 | 無限重連迴圈，浪費 CPU/Mach port | 連線無聲斷開，零背景活動 |
| 主 App 重啟後恢復 | 重連卡在 30s 退避 + 斷路器 | 下次操作（requestSet/sendLogBatch）按需建立新連線 |
| CPU 開銷（背景） | 心跳 timer\(已移除\) + 重連嘗試 + circuit breaker timer | 零 |
| log 串流首次延遲 | 0ms（連線已就緒） | ~1-5ms（TCP localhost handshake） |
| requestSet/sendStreamEnd | 0ms（連線已就緒） | ~1-5ms（每次建立新連線） |

### 追修：`waitForReady()` 時序競爭（Race Condition）

**問題**：`waitForReady()` 先把 `_connect()` dispatch 到 serial queue，再 dispatch 自己到同一條 queue 設定 `readyContinuation`。但 NWConnection 的 `.ready` 回呼也跑在同一條 queue 上，且因為 `connection.start()` 的 async callback 排隊比 `waitForReady` 的 dispatch **更早**，所以順序變成：

```
queue 執行順序:
  1. _connect() → 建立 NWConnection、呼叫 start()、return
  2. (NWConnection async callback) state handler 觸發 .ready
     → 此時 readyContinuation 還是 nil → 錯過
  3. waitForReady 的 dispatch → 設定 readyContinuation
     → .ready 已錯過 → 10s timeout → 重試 → 再次 timeout → 推流失敗
```

**修正**（`Socket.swift:167`）：將 `waitForReady` 從 **continuation 通知**改為 **polling 模式** — 每 100ms 檢查 `connection?.state`：

| 狀態 | 結果 |
|------|------|
| `.ready` | 立即返回 true |
| `.failed` / `.cancelled` | 立即返回 false |
| `nil`（尚未建立）/ `.preparing` / `.waiting` | 繼續等待 |
| 10s 無變化 | 返回 false |

同步簡化了 state handler：移除 `self.queue.async { ... }`（handler 已在 `queue` 上），改為直接同步呼叫 `readyContinuation?.resume()`。

### 追修：`sendAudioLive` / `sendSettings` 未建立連線（音量即時更新失效）

**問題**：`sendAudioLive()` 和 `sendSettings()` 直接呼叫 `sendPayload()`，但 `sendPayload()` 檢查 `guard let con = connection` — 在 on-demand 架構下，每個操作用完就關閉連線，所以 `connection` 通常是 `nil`，音量資料被靜默丟棄。

**修正**：兩者都改為先 dispatch 到 `queue`，若 `connection?.state != .ready` 則呼叫 `_connect()` 建立新連線，再送出 payload。連線不會主動關閉，由後續 volume data（每 1 秒來自 `VolumeNotifier`）維持活性；離開 audio page 後 server idle timeout 自動清理。

| 場景 | 改前 | 改後 |
|------|------|------|
| 切到 audioPage | 無任何音量資料送達 | 每秒自動建立連線、即時更新音量 |
| audioPage 停留期間 | 無任何音量資料送達 | 連線由持續 volume data 維持，零中斷 |

### 追修：`sendPayload` 的 30s DispatchWorkItem 造成 libdispatch over-release（Crash）

**問題**：`sendPayload` 使用 `DispatchWorkItem` + `queue.asyncAfter(deadline: .now() + 30)` 實作 send timeout。此 `DispatchWorkItem` 同時被三個持有者強引用：
1. `asyncAfter`（30s 到期前保持）
2. `.contentProcessed` closure（NWConnection send completion 回呼）
3. 區域變數（`sendPayload` 返回後釋放）

當 `asyncAfter` 在 30s 到期觸發（執行關閉連線），然後 `.contentProcessed` 才在同一條 serial queue 被調度時，三方交叉持有造成 `libdispatch` runtime 檢測到 `API MISUSE: Over-release of an object`（`liveAPP-2026-07-03-060542.ips`）。

**修正**：完全移除 30s `DispatchWorkItem`。在 on-demand 架構下：
- 連線短暫，成功就送出，失敗則由 state handler（`.failed`）清理
- 上層已有 `withTimeout`（15s for `requestRTMPKEYAndLog`）和 Task cancellation 保護
- `con.send(content:completion:)` 的 `.contentProcessed` callback 是唯一的 completion 通知機制，不再經過 dispatch 物件

| 改善 | 說明 |
|------|------|
| 移除 dispatch 物件 | 不再有 `DispatchWorkItem` 被三方交叉持有 |
| Crash 風險 | 消除 libdispatch over-release 的可能路徑 |
| 行為不變 | 網路超時由 NWConnection 本身處理，無需額外 timer |

---

## 9. 廣播暫停/恢復 — VideoToolbox encoder 重建與前景復原

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
    
    // 1. 按需重建 Socket 連線（背景可能斷開）
    SocketClient.shared.connect()
    
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
| Socket 連線 | 背景斷開後無人處理 | `connect()` 按需建立新連線 |
| 斷線監控 | 背景時 Task 被 cancel 不重啟 | `startDisconnectMonitor()` 重啟 |

---

## 10. LogTextView 頁面切換崩潰 + LogBuffer 記憶體上限

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

### 記憶體優化：Coordinator 三層重複儲存

**問題**：`LogTextView.Coordinator` 存在三層重複儲存：
```
LogModel.messages (1000 條)
  → Coordinator.messageLines (10000 條)    ← 問題①
  → UITextView.textStorage (NSAttributedString)  ← 問題②
  → appendedUUIDs (20000 個 UUID)          ← 問題③
```
- **問題①**：`messageLines: [String]` 保存 10000-15000 條訊息字串，與 `tv.text` 內容完全重複
- **問題②**：NSAttributedString 在逐條 append 時產生大量 attribute runs，每個字元都攜帶 font/color metadata，10000 行時開銷巨大
- **問題③**：`appendedUUIDs: Set<UUID>` 最多存 20000 個 UUID 純粹為了去重，但 LogModel 本身已有 `removeFirst` 管理，從未命中過

**修正**（`ContentView.swift:1192-1290`）：

| 項目 | 改前 | 改後 | 節省（估） |
|------|------|------|-----------|
| `maxLines` | 10000（trim 時 15000） | **3000** | ~7-10 MB |
| `messageLines` | 獨立陣列 + tv.text 雙重儲存 | **移除**，僅用 `currentLineCount` 計數，trim 直接解析 tv.text | ~2-3 MB |
| `appendedUUIDs` | 20000 個 UUID（~800KB） | **移除** | ~800 KB |
| NSAttributedString attributes | 每批 append 自建 font/color dictionary | 移除 attributes，繼承 UITextView 預設樣式 | 微量 |
| Trim 時重建 | 遍歷 15000 條做 `"\(i): \(line)"` 字串拼接 | 從 tv.text 解析行數，`suffix(3000)` 後重新編號 | CPU 降 |

**合計節省約 10-14 MB**（主要來自 NSAttributedString 行數減少 70%）。

---

## 整體性能預期

## 整體性能預期

| 指標 | 改前 | 改後 |
|------|------|------|
| Socket 連線穩定性 | burst log → timeout → 斷線重連 loop | batch 限流，連線穩定；主 App 被殺後零重連浪費 |
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
| **LogTextView 日誌頁記憶體** | **~12-18 MB**（10000 行 NSAttributedString + 10000 條 messageLines + 20000 UUIDs） | **~2-4 MB**（3000 行 NSAttributedString，無重複陣列） |
| 頁面切換穩定性 | 快速切換 onLogPage/onAudioPage 高機率崩潰 | window nil 檢查，安全防護 |
| 背景串流 LogBuffer 記憶體 | 無上限，長時間背景高機率 OOM | 上限 5000 條，自動截斷 |

---

## 11. broadcastResumed 視訊管線重建 + 側載清除日誌優化

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

## 12. 音量頁即時 RMS 節流（防 socket 洪流斷線）

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

## 13. Video 管線連續失敗偵測與自動重建

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

## 14. 清除日誌按鈕修復

### 問題
`logModel.clearLogs()` 只清 `LogModel.messages`，但 `LogTextView.Coordinator` 有自己的 `messageLines`、`appendedUUIDs` 和 UITextView 文字內容未被清除，頁面上的日誌仍顯示。

### 修正
- `Coordinator` 新增 `clearText()`：清空 `messageLines`、`appendedUUIDs`、`appendQueue`、`currentLineCount` 及 `tv.text`
- 「清除日誌」按鈕呼叫 `coordinator?.clearText()`

---

## 15. GPU Texture Cache 隔離 + cleanup 時序修正

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

**Texture Cache 精簡**（`GPUVideoRotator.swift:138,396-404,653`）：移除每個 rotator 自建 cache 的邏輯。`CVMetalTextureCache` 的 key 綁定 pixel buffer 指標，每幀都是不同的 `CVPixelBuffer`，幀幀 cache miss，建了也用不到。改回 `MetalContext.shared.ensureTextureCache()` 單一共享 cache，不再每實例重複建立。

### 預期改善
| 場景 | 改前 | 改後 |
|------|------|------|
| 前景恢復後 video | 共用 cache 被 flush → 新 rotator texture 失效 → 斷流 | 共享 cache 不 flush，各 rotator 直接取用 |
| 舊 actor GPU 資源 | Task 無法存取（已 nil）→ 從未釋放 | 值捕獲先存 local → 正確 cleanup |
| 多次 rebuildVideo | 第二次起舊 cache 已被前次沖掉 | 單一共享 cache，不掉不重建 |

---

## 8. 原始音訊管線效能優化（AudioProcessor original path）

### 問題
使用原始音訊管線 (`UseOringin = true`) 時，音訊出現斷斷續續（stutter）。根因有三：

1. **每秒 ~100 次 heap allocation**：`amplifySIMD()` 原本是自由函數，每次呼叫都 `UnsafeMutablePointer<Float>.allocate(capacity:)` / `deallocate()`。app + mic 雙軌合計每秒近百次 malloc/free，造成 heap 碎片化與 GC 壓力。

2. **每秒百次 CMSampleBuffer shallow copy**：`retimeAudioBuffer()` 在 `processRMS()` 外部呼叫，每次 buffer 入隊都建立一份 shallow copy。但 `processRMS()` 受 1 秒間隔節流保護 — 99% 的呼叫中這份 copy 是浪費的。CMSampleBuffer 的淺拷貝雖然不複製音訊資料，但仍需分配新物件並 retain block buffer。

3. **Drop gate 無同步 data race**：`isEnqueuingApp` / `isEnqueuingMic` 在 ReplayKit callback thread 設為 `true`，在 `Task.detached` 的 utility thread 設為 `false`，跨執行緒讀寫無任何同步保護，可能導致不必要的掉幀。

### 修正

| 項目 | 改前 | 改後 |
|------|------|------|
| **Gain buffer** | `UnsafeMutablePointer<Float>.allocate(capacity:)` 每次分配/釋放 | `_appGainBuffer` / `_micGainBuffer` 兩個 per-track 預分配 `[Float]`，只在 buffer 不足時擴容一次，後續全部重用 |
| **retimeAudioBuffer** | `enqueue()` 內每次都呼叫 → 傳入 `processRMS()` | `retimeAudioBuffer()` 移入 `processRMS()` 內部，只在一秒間隔 RMS 真正觸發時建立 shallow copy |
| **Drop gate** | 裸 `Bool` 跨線程無保護讀寫 | 新增 `os_unfair_lock` (`_enqueueLock`)，讀寫經 `setEnqueuing()` helper 統一保護 |

### 預期改善
| 場景 | 改前 | 改後 |
|------|------|------|
| 原始音訊（增益 > 1.0） | 每秒 ~100 次 heap alloc + 每秒 ~100 次 CMSampleBuffer 淺拷貝 + 可能因 data race 誤掉幀 → 音訊斷續 | 零 heap alloc（buffer 重用）、99% 跳過 shallow copy、無 data race → 音訊流暢 |
| 原始音訊（增益 ≤ 1.0） | 每秒 ~100 次 shallow copy + data race 掉幀 | 每秒 1 次 shallow copy（僅 RMS），其餘跳過 |
| 專用 DSP 管線 | 同上（retimeAudioBuffer + data race） | shallow copy 同樣移入 RMS 內部，drop gate 同步保護 |

### 記憶體影響
- **改前**：無持久 buffer，每秒 ~2KB × 100 = ~200KB heap churn
- **改後**：兩個 per-track `[Float]` buffer，常駐約 8KB（4KB each @ 1024 samples），只在 buffer 不足時一次性擴容

---

## 9. GPU 密集型遊戲導致 ReplyKit 掉幀（已知 iOS 系統限制）

### 現象

當 GPU 密集型遊戲（如 第五人格）內開啟高負載子頁面（活動頁、內嵌小遊戲等），直播幀數會瞬崩至 2-10 fps，但遊戲本身遊玩不受影響。關閉子頁面後幀數立刻恢復。

### 測試案例（2026/06/30，log-5.txt）

| 時間 | `videoInputFrames`/秒 | 事件 |
|------|----------------------|------|
| 03:32:33 | 59 | 遊戲主畫面正常 |
| 03:32:36 | 29 | 點開活動子頁面，開始下滑 |
| 03:32:38 | 3 | 2 秒內崩到 3fps |
| 03:32:44 ~ 03:33:29 | 2（持續 45 秒） | 活動頁期間鎖死 2fps |
| 03:33:30 | 48 | 關閉活動頁，瞬間恢復 |

`videoInputFrames` 是 ReplayKit 交給我們的原始幀數，降到 2 代表 **上游根本沒收到幀**，我們的 video processor 全程正常運作（無 rebuild、無逾時、無 watchdog 觸發）。

### 根因

這是 iOS 系統級 GPU 排程設計，**非我們的 bug、非遊戲優化問題**：

```
前景 App（遊戲）> 螢幕合成器（ReplayKit source）> 廣播擴展（我們）
```

iOS 永遠優先保障前景 App 的 GPU 時間。當遊戲吃滿 GPU，螢幕合成器（負責產出 ReplayKit 擷取畫面）的 GPU 配額趨近於零，導致 ReplayKit 收到的幀數崩潰。我們的後處理（GPU 旋轉、編碼）發生在擷取之後，無法影響上游的擷取率。

### 影響範圍

- **所有 ReplyKit 廣播 App 都會遇到**，非本專案獨有
- 發生條件：前景 App 的 GPU 使用率接近 100%
- 遊戲本身不受影響（前景最高優先權）
- 音訊不受影響（音訊不經過 GPU 合成器）

### 緩解方向（已評估）

| 方向 | 可行性 | 原因 |
|------|--------|------|
| GPU 旋轉降級到 CPU | 無效 | 瓶頸在擷取端（螢幕合成器），不在後處理端 |
| 降低編碼碼率/解析度 | 無效 | 瓶頸在 ReplayKit 擷取，不在編碼 |
| 調整 `videoBuffer` 值 | 無效 | HaishinKit 內部緩衝不影響 ReplayKit 擷取率 |
| 更換遊戲 / 避開高負載場景 | 使用者層面 | 唯一有效但非技術解 |

### 可觀測指標

RTMP 吞吐量 log 中的 `videoInputFrames` 是最直接的指標。若此值持續低於 20 且 `[VProc]` 無異常（`active:true processing:false`），即為 ReplayKit 被系統節流。我們不該對此觸發 rebuild 或 watchdog。

---

## 10. 設備資訊圖表凍結修復（DeviceView Charts）

### 問題
設備資訊頁（`OtherView.swift`）的三個圖表（CPU、RAM、Disk I/O）開啟一段時間後全部卡住不更新。兩個疊加問題：

1. **`DataPoint.id = UUID()`** — 每秒為 5 個資料點各產生新 UUID。Swift Charts 的 `ForEach` 依賴 `Identifiable` 做 diff，ID 每秒全換 → Charts 每次視為全新資料集重繪，失去動畫更新能力，且無效的 diff 計算浪費 CPU。

2. **`Timer.publish(...).autoconnect()`** — 使用 SwiftUI `.onReceive` 模式。在 `List` + `TabView` 的組合下，SwiftUI 的訂閱管理可能中途斷線（例如頁面切換後重建），且無恢復機制，timer 永久停止。

3. **切頁未清理** — 從設備資訊頁切到其他分頁時，歷史陣列未清空。回來後 `onAppear` 直接接續舊資料，圖表瞬間從 60 秒前的資料跳到最新，視覺上是「卡住」後突然更新。

### 修正

| 項目 | 改前 | 改後 |
|------|------|------|
| **DataPoint ID** | `let id = UUID()` 每秒新生 | `let id: Int` 配合 `dataPointCounter &+= 1` 遞增，跨秒穩定 |
| **Timer 生命週期** | `.onReceive(Timer.publish(...).autoconnect())` | `onAppear` 手建 `Timer` + `RunLoop.main.add(..., forMode: .common)`，`onDisappear` invalidate |
| **切頁清理** | 無 | `onDisappear` 內 `removeAll()` 五個 history 陣列 + invalidate timer |

### 預期改善
| 場景 | 改前 | 改後 |
|------|------|------|
| 圖表更新 | Charts diff 全失效（UUID 全換）→ 無動畫、卡頓 | 穩定 Int ID → Charts 正確識別新增/移除點，平滑動畫 |
| 長時間開啟 | Timer 訂閱隨機斷線 → 圖表凍結 | Timer 由 onAppear/onDisappear 顯式管理，不依賴 SwiftUI 訂閱 |
| 頁面切換 | 回來後舊資料殘留 → 瞬間跳到最新秒 | 清空重來，每次進入都是乾淨的 60 秒累積

---

## 11. 背景記憶體釋放（降低 App 被 Kill 風險）

### 背景

iOS 的 Jetsam 機制會在記憶體緊張時優先終止背景 App。主動在進入背景時釋放非關鍵記憶體能降低被終止的機率。

### 既有處理

Memory Warning 時已有：
- `PIPService.handleMemoryWarning()`：清除訊息圖層、降 FPS、釋放 `pixelBufferPool`
- `logModel.clearLogs()`：清空日誌緩衝
- `SocketServer.shared.releaseMemory()`：清空 socket 發送佇列

### 缺口分析

| 資源 | 檔案 | 大小（估） | 原有釋放時機 | 風險 |
|------|------|-----------|------------|------|
| PiP 圖片快取 `NSCache` | `PIPContent.swift` | ~20MB | ❌ 從未釋放 | 即使 PiP inactive 仍佔 20MB |
| PiP `pixelBufferPool` (3× CVPixelBuffer) | `PIPService.swift` | ~9MB | 僅 Memory Warning | PiP inactive 時不釋放 |
| PiP render timer / pipeline | `PIPService.swift` | ~1MB | 僅 `stopPiP()` | PiP inactive 時繼續運轉 |
| PiP 訊息 CoreAnimation 圖層 | `PIPContent.swift` | ~2-5MB | 僅 Memory Warning | PiP inactive 仍佔 |
| LogModel 日誌 (1000 條) | `liveAPPApp.swift` | ~300KB | 僅 Memory Warning | 可提前釋放 |
| Socket 佇列 | `Socket.swift` | 動態 | 僅 Memory Warning | 可提前釋放 |

### 修正

| 檔案 | 新增內容 | 行為 |
|------|---------|------|
| `PIPContent.swift:62` | `PiPImageCache.clear()` | 清除 `NSCache` 所有物件 + 取消進行中的圖片下載 |
| `PIPService.swift:1159` | `releaseNonCriticalMemory()` | 若 `didStartPiP == false`：取消 render timer、釋放 pipeline、`pixelBufferPool = nil`、清除 messagesLayer。無論 PiP 狀態：清除圖片快取 |
| `liveAPPApp.swift:939` | scenePhase → `.background` | 呼叫 `releaseNonCriticalMemory()` + `logModel.clearLogs()` |

### 保留資源

進入背景時**不釋放**的資源：
- **SocketServer**：由 background task chain 保護，log 管線需要持續運作
- **PiP 渲染管線**（當 `didStartPiP == true`）：使用者正在觀看子母畫面中，須保持 pixel buffer pool 和 display layer

### 預期改善

| 指標 | 改前 | 改後 |
|------|------|------|
| 背景常駐記憶體（PiP inactive） | ~40+ MB | ~10+ MB，可回收 ~30MB |
| 背景被 Jetsam 終止機率 | 高（~30MB 非關鍵記憶體佔用） | 較低（非關鍵記憶體已釋放） |
| PiP inactive 時背景行為 | render timer 繼續跑、GPU 持續消耗 | render timer 停止、GPU 空閒 |
| 恢復前景後行為 | pixelBufferPool 可能仍為 nil 無重建 | `appWillEnterForeground()` 自動重建 pool |

### 後續補充：日誌頁文字緩衝（2026/06）

背景釋放仍遺漏 **LogView 的 Coordinator**：該物件持有 `messageLines: [String]`（最多 10000 行）及 `UITextView.textStorage`（NSAttributedString），即使 `logModel.clearLogs()` 已清除 model 陣列，text view 的介面文字仍佔 ~6-7MB。

**修正：** `LogView` 加入 `@Environment(\.scenePhase)` 監聽，在 `scenePhase == .background` 時同時 call `logModel.clearLogs()` + `coordinator?.clearText()`，完整釋放日誌文字記憶體。

### 預期改善總結

| 指標 | 改前（預估） | 改後（預估） |
|------|------------|------------|
| PiP inactive 時背景常駐記憶體 | ~40-50MB | ~10-15MB |
| 日誌頁文字緩衝 | ~6-7MB（永不釋放） | ~0MB（背景自動清除） |
| 總背景常駐記憶體 | ~90-100MB | ~55-65MB |
| Jetsam 終止相對風險 | 高 | 中低（同等記憶體壓力下優先權降低） |

---

## 12. GPU 視訊管線瘦身（移除預設開啓的 Sharpen、懶載入 Pipeline）

### 問題

`GPUVideoRotator.swift` 的視訊旋轉管線存在三個效能浪費：

1. **永遠開啓的 Sharpen Post-Pass**：`renderPlaneYUV()` 無論 `.live` 還是 `.quality` 模式都在旋轉後加上 unsharp mask 銳化（`.live` 用 0.15、`.quality` 用 0.25），這使每幀 GPU 從 1 個 dispatch 變成 2 個 dispatch，對遊戲直播的畫面沒有任何肉眼可辨的改善（遊戲畫面本身已經夠銳利），反而可能引入 ringing artifacts。

2. **多餘的 Pipeline 編譯**：`buildComputePipeline()` 每次初始化都編譯三條 pipeline（`rotateNV12_bilinear`、`rotateNV12_bicubic`、`unsharpY`），即使使用者只使用 `.live` 模式，bicubic 和 unsharp 的 GPU shader 仍被編譯並佔用記憶體。

3. **閒置的暫存 Y Texture**：為了 sharpen post-pass 準備的 `tempYTexture`（1920×1080 R8Unorm）額外佔用 GPU 記憶體。

### 修正

| 項目 | 改前 | 改後 |
|------|------|------|
| **Sharpen Post-Pass** | `qualityMode == .live` 時 `sharpenAmount = 0.15`，`.quality` 時 `0.25`，永遠 >0 永遠開啓 | 完全移除 `sharpenPipeline`、`tempYTexture`、`useSharpen` 相關程式碼 |
| **Pipeline 編譯** | 每次初始化編譯 3 條 pipeline | 根據 `qualityMode` 只編譯對應的 1 條（`ensureMetalResources()` 中用 switch 選取） |
| **shader 載入策略** | 全部載入 | 使用者選哪個載哪個，切換模式時重建 rotator 後重新編譯 |
| **GPU dispatch / 幀** | 2 次（旋轉 + sharpen） | 1 次（僅旋轉） |

### 功能影響

- **畫質不變**：移除 sharpen 對遊戲直播畫面無負面影響（遊戲 rendering 本身已含銳化）
- **GPU 負擔**：每幀從 2 dispatches → 1 dispatch，在 60fps 下相當於每秒減少 60 次 GPU 編碼器啓動
- **編譯時間**：首次初始化 Metal pipeline 的時間約縮減 60%（只編譯 1 個 kernel 而非 3 個）

---

## 13. Extension 早期日誌檔案（Early-Log）

### 問題

Extension 的除錯日誌（`sendlog()`）在 socket 就緒前只寫入 ring buffer（1000 行），無法從外部讀取。當 socket 連線失敗時，無法獲得連線階段的日誌來診斷問題。

### 設計

| 項目 | 說明 |
|------|------|
| **檔案名稱** | `early-log.txt` |
| **儲存位置** | App Group 共享目錄 `group.nuclear.liveAPP`（無 App Group 時 fallback 到 extension 的 `documentDirectory`） |
| **寫入時機** | 每個 `sendlog()` / `addDebugLog()` 呼叫即時寫入（無關 socket 是否就緒） |
| **行數上限** | 2000 行，超過時保留最新 2000 行 |
| **是否跳過 Sideload** | **不跳過** — 不同於 `writeLogToFile`（`enableLog` 為 `false` 時 socket 路徑用），early-log 永遠寫入 |
| **讀取方式** | 生產環境：主 App 可讀取共享目錄；側載：Xcode → Devices → Download Container 或工具讀取 |

### 實作變更（`Event.swift`）

- 新增 `writeEarlyLogToFile()`：無 `isSideload` guard 的檔案寫入
- 新增 `trimEarlyLogFileIfNeeded()`：以 `maxEarlyLogLines（2000）` 為上限裁剪
- 在 `log()` 及 `addDebugLog()` 的 `logQueue.async(flags: .barrier)` 區塊內加入 `writeEarlyLogToFile(logMessage)`

### 用途

- 診斷 socket 初期連線問題（`requestSet` timeout、`waitForReady` 失敗）
- 觀察 `onAudioPage` 等事件是否確實觸發
- 確認 `audioProcessor?.updatePage(status:)` 是否被呼叫
- 追蹤 `_closeConnection()` 與 `liveAPP.SocketRestart` 之間的因果關係