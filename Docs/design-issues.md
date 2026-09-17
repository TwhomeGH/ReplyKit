# 設計問題紀錄

## 1. Processor 初始化在 RTMP 連線之後

**檔案**: `ReplyKIT/SampleHandler.swift`

**問題**: `initProcessors()` 放在 `broadcastStarted()` 中 `await startRTMP()` 之後。由於 `startRTMP()` 內部的 `rtmpConnection?.connect()` 是非同步網路呼叫，若 RTMP 伺服器無法連線，整個 `startRTMP()` 會卡住永不返回，導致 `initProcessors()` 永遠不會執行。

**影響**:
- `audioProcessor` / `videoProcessor` 為 nil
- `processorsInitialized` 永遠為 false
- 所有音視頻幀在 `processSampleBuffer` 中被丟棄
- `onAudioPage` 等 socket 事件因 `audioProcessor` nil 而無法套用（即使有延遲重試也無效，因為 `processorsInitialized` 永不為 true）

**修復**: 將 `initProcessors()` 移至 `startRTMP()` 之前，不依賴 RTMP 連線狀態。

---

## 2. MediaMixer.startRunning() 在 RTMP 連線成功後才呼叫

**檔案**: `ReplyKIT/SampleHandler.swift`

**問題**: `mediaMixer.startRunning()` 被放在 `startRTMP()` 的 `do` 區塊中，在 `connect()` 與 `publish()` 成功後才執行。若連線失敗（catch 區塊），`startRunning()` 永遠不會被呼叫。

**影響**:
- `mediaMixer.isRunning` 永遠為 false
- `AudioProcessor.enqueue()` 中 `guard await mediaMixer.isRunning else { return }` 丟棄所有音訊
- `VideoFrameProcessor.process()` 中 `guard await self.mediaMixer.isRunning else { return }` 丟棄所有視訊
- 即使 processor 已初始化，管線依然完全停擺

**修復**: 將 `mediaMixer.startRunning()` 移至 `startRTMP()` 之前，在 processor 初始化後立即啟動。

---

## 3. Reconnect 回呼 .started 在初始連線時錯誤停止 MediaMixer

**檔案**: `ReplyKIT/SampleHandler.swift`

**問題**: `RTMPConnection` 的 reconnect state machine 在**初始連線**時也會發射 `.started` 事件。原本的程式碼在 `.started` 中無條件呼叫 `mediaMixer.stopRunning()`，導致初始連線嘗試期間 MediaMixer 被停止。

**影響**:
- 初始連線時（甚至還沒成功過），MediaMixer 就被 `stopRunning()`
- 如果首次連線失敗（`.failed`），MediaMixer 不會被重新啟動
- 整個串流期間 MediaMixer 都處於停止狀態

**修復**: `.started` 中不再停止 MediaMixer。重連期間管線持續運行，由 RTMP stream 內部緩衝處理。

---

## 4. SocketServer data race on connections

**檔案**: `liveAPP/Socket.swift`

**問題**: `queueSend()` 方法在 `queue` 外部直接讀取 `connections.values`。`connections` 字典僅在 `queue` 上被修改（`removeConnection`、`handleNewConnection`、`stopInternal`、`suspend`），但 `broadcast()` 可以從任何執行緒呼叫。Swift `Dictionary` 在並發讀寫時會產生未定義行為。

**影響**: 內部儲存結構被破壞後，可能導致對已釋放物件的 double-release，表現為 `API MISUSE: Over-release of an object` 崩潰。

**觸發條件**: `broadcast()` 在非 `SocketServerQueue` 執行緒上被呼叫（例如主執行緒的設定變更、Darwin notification 處理等）。

**修復**: `queueSend()` 改為 `queue.async { ... }` 內讀取 `connections`。

---

## 5. DispatchWorkItem 在 sendTimeout 中的 over-release

**檔案**: `liveAPP/Socket.swift`

**問題**: `sendNextPayload()` 使用 `DispatchWorkItem` 作為 send timeout watchdog。該 work item 同時被 `asyncAfter` 保留（系統層）與 `.contentProcessed` callback closure 捕獲。當 send 在 timeout 之前完成時，`.contentProcessed` 呼叫 `sendTimeout.cancel()`，而 `asyncAfter` 的 pending timer 隨後嘗試 release 同一個 work item。兩個路徑在同一個 serial queue 上交錯時，libdispatch 的 `_os_object_release` 可能在 retain count 為 0 時被呼叫。

**影響**: 在頻繁的 send/response 情境下（特別是在 RTMP 重連期間有大量 log 傳送），會觸發 `API MISUSE: Over-release of an object` 崩潰。

**修復**: 使用 `[String: Bool]` flag 取代 `DispatchWorkItem`。timeout 處理改為閉包內檢查 flag 是否存在，`.contentProcessed` 完成時清除 flag。

---

## 6. DispatchWorkItem 在 scheduleRestart 中的 over-release

**檔案**: `liveAPP/Socket.swift`

**問題**: `scheduleRestart()` 每次被呼叫時建立新的 `DispatchWorkItem`、`cancel()` 舊的，並存入 `restartWorkItem`。被 cancel 的 work item 仍然被 `asyncAfter` 保留。當短時間內多次呼叫（例如收到多個 CFNotification），被 cancel 的 work item 與新的 work item 的派發與釋放交錯，可能觸發 libdispatch 的 over-release 偵測。

**影響**: 在收到 `liveAPP.SocketRestart` Darwin notification 時可能觸發崩潰。

**修復**: 改用 UUID key 比對機制取代 DispatchWorkItem。

---

## 7. 背景 Socket 保活語意修正

**檔案**:
- `liveAPP/liveAPPApp.swift`（背景時啟動短 background window + 排程 socket refresh）
- `liveAPP/PIPService.swift`（移除舊 background task chain）
- `liveAPP/BackgroundTaskManager.swift`（封裝短 background window 與 BGTaskScheduler refresh）
- `liveAPP/Info.plist`（新增 `BGTaskSchedulerPermittedIdentifiers`）

**問題**: 原有使用 `UIApplication.beginBackgroundTask(expirationHandler:)` 搭配 chain 模式嘗試讓 app 在背景持續存活，但有兩個根本缺陷：

1. **Chain 只延一次就斷**：內層 expiration handler 沒有再包一層，最多延一次（總共 30s~3min），之後 app 被 suspend。
2. **不檢查 `.invalid`**：`beginBackgroundTask` 在系統無法給予時間時回傳 `UIBackgroundTaskInvalid`，但程式碼未檢查就直接使用，導致後續 `endBackgroundTask` 行為異常。

此外，`BGTaskScheduler` 不是 socket 常駐保活機制。系統不保證 5 秒後執行，也不保證固定週期；它只能作為機會型 refresh。PiP 場景仍主要依靠 `AVAudioSession.Category.playback` + `audio` background mode。

**修復**:
1. **保留短 background window**：進背景時呼叫 `beginSocketBackgroundWindow()`，只期待系統允許的短時間收尾窗口，不做 chain。
2. **BGTaskScheduler 改為 refresh**：以 `BGAppRefreshTask`（identifier: `com.nuclear.liveAPP.socket.keepalive`）排程下一次機會型喚醒；handler 執行 `SocketServer.shared.start()` + `sendKeepalive()`，10 秒後完成。
3. **新增 `BackgroundTaskManager` 單例**：統一管理註冊、排程、短背景窗口、取消與 handler 完成。
4. **`AppDelegate` 不存在問題**：因為專案使用 SwiftUI `@main` App 結構，沒有 `AppDelegate`；所有初始化在 `liveAPPApp.init()` 中完成。

**運作流程**:
```
App 進背景 → beginSocketBackgroundWindow() 取得短背景窗口
  → scheduleSocketRefresh() 排程 BGAppRefreshTask（最早約 15 分鐘，實際由系統決定）
  → 若系統執行 handler
    → 再排下一次 refresh
    → SocketServer.shared.start()
    → sendKeepalive() 確認通道
    → 10 秒後 setTaskCompleted
App 回前景 → cancelAll() + endSocketBackgroundWindow()
```

**2026-08 補充**：正式接上 `beginSocketBackgroundWindow()`（此前 `.background` 只排程、未啟動短窗口）；Info.plist 補上 `fetch` background mode（BGAppRefreshTask 所需，`processing` 為舊型別殘留）；`scheduleSocketRefresh()` 於 PiP 活躍時跳過排程、`stopPiP()` 在背景狀態下補排程；handler 改在背景佇列執行。詳見 pip-performance-improvements.md Section 41。


---

## 8. 背景執行緒改 @Published → SwiftUI/AttributeGraph 死鎖（0x8BADF00D）

**檔案**:
- `liveAPP/Socket.swift`（`handleDecodedPayload` 在背景佇列上呼叫）
- `liveAPP/ContentView.swift`（`LiveVolumeModel` 在背景被寫入）

**問題**: `SocketServer.handleDecodedPayload` 跑在背景的 `SocketServerQueue`（`Socket.swift`），卻直接呼叫
`LiveVolumeModel.shared.updateVolumes(...)`（`ContentView.swift`），在**背景執行緒寫入 ObservableObject 的 `@Published`**。

SwiftUI 於是就在**背景執行緒**啟動 AttributeGraph 更新，並取得全域的 movable lock；更新途中要動到
TabView（`UIKitAdaptableTabView` → `UITab.setImage:` → diffable data source `applySnapshot`），而 UIKit 這段
**必須在 main**，便以 `_dispatch_sync_f_slow` **同步**跳回 main 而卡住（鎖仍握著）。同一時間主執行緒在 runloop
observer（`NSRunLoop.flushObservers` → `UpdateGroup.begin()`）要拿**同一把** movable lock。兩者互等：

```
thread #7(背景): 握著 movable lock ──等──> main (applySnapshot 同步)
main           : 等 movable lock   ──等──> thread #7
                    ↑ 循環等待 = 死鎖 → scene-update watchdog 0x8BADF00D 砍掉 App
```

**為什麼難以察覺**:
- 死鎖的兩半在**不同執行緒**：main 的 stack 只看到 `_MovableLockLock` 在等，真正的持有者（背景那條）**完全不出現在 main 的 stack**。
- 需要時序剛好對上才會爆（背景更新進行中、且 main 同時進入 runloop flush），因此是**偶發**。
- 改 `@Published` 本身不會當；是「SwiftUI 只有一把更新鎖」與「UIKit 必須回 main」互撞。
- `bug_type 309` 常被誤讀成 stack overflow；真正的死因要看 `termination` 的 `0x8BADF00D`（watchdog deadlock）。

**影響**: 主執行緒永久卡死，App 被 watchdog SIGKILL（使用者看到閃退）。

**修復**: 所有 UI 狀態（ObservableObject `@Published`）必須在主執行緒改。
`LiveVolumeModel` 標為 `@MainActor`；`Socket.swift` 的 `audioLive` / `logbatch` 呼叫點包 `Task { @MainActor in ... }`；
CFNotification observer 亦同。`VideoHealthModel` / `AudioHealthModel` 原本就已在 `record()` 內用 `DispatchQueue.main.async`。

**通則（避免再犯）**:
1. 從 socket / 網路 / log / **任何背景佇列**回來的資料，只要會寫 `@Published`（或任何 SwiftUI 狀態），一律先 hop 回 main：
   `Task { @MainActor in ... }`（與本專案既有 `StreamActivityManager` 用法一致），不要在背景直接寫。
2. 新增 ObservableObject 時，**優先整個 class 標 `@MainActor`**，讓編譯器擋掉背景寫入，而不是靠自律。
3. 同一個背景 callback 會改多個 model 時，要逐一檢查：只要有一個漏 hop main 就會中。
4. 診斷這類偶發閃退：用 `crash_trace.py -s <UUID 相符的 dSYM>`，看 `[死因]` 與「死鎖分析」的跨執行緒堆疊（詳見 `crash-tracing.md`）。
