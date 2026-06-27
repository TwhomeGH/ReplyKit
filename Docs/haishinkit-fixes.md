# HaishinKit 修正記錄

## 問題：RTMP 連線卡在 `handshakeDone`，無法進 `connected`

### 現象

- RTMP TCP handshake 成功後狀態卡在 `handshakeDone`
- 伺服器等不到 `connect command`（SRS 30s timeout）
- 音影 sample 正常流入 MediaMixer，但從未 publish
- Twitch / SRS 皆受影響

### 根因

**`RTMPChunk.swift` — `chunkSize.didSet` 使用 `Data(count:)` 抹除 buffer**

```
RTMPChunkBuffer.chunkSize 從 128 → 8192（收到伺服器 Set Chunk Size）時：
  didSet {
    data = Data(count: newCount)    ← 整個 buffer 被零填充取代
  }
```

若 `outputBuffer` 已包含待發送的 `connect command`，該指令被抹除，導致伺服器永遠收不到連線請求。

### 修正

```
RTMPChunk.swift:138

- data = Data(count: newCount)
+ data.append(Data(count: newCount - data.count))
```

保留 buffer 中既有的資料，只將剩餘空間補零至所需大小。

---

---

## 問題二：中串流斷線後自動重連未觸發，5 秒後斷線

### 現象

- RTMP 連線成功後約 5 秒 Twitch 關閉連線
- `totalBytesOut` 極低（僅 7KB），音影數據停留在 MediaMixer 未送出
- `斷線監控觸發` 每秒無限噴發，主 App 被 iOS 後台殺死

### 根因

**`RTMPConnection.swift:444-450` — `recv()` 掉線錯誤從未觸發 `startReconnection()`**

`performConnect` 內部的背景 `recv()` Task 負責持續接收伺服器數據。當 `endOfStream` 發生時，`AsyncStream` 正常結束（非拋錯），`for await` 迴圈離開後直接呼叫 `close()`。**中串流斷線的錯誤路徑與 `startReconnection()` 完全隔離**，底層已有的 `resumePublishing()` 機制（`performConnect` line 458-461）從未有機會執行。

```
                 初始連線失敗                         中串流斷線
  connect() ──→ 拋錯 ──→ startReconnection()      recv() 結束 ──→ close() only
                           │                                            │
                           ↓                                            ↓
                      performConnect()                             程式靜止
                      resumePublishing() ✓
```

### 修正

```
RTMPConnection.swift:447-458

  // recv() 串流正常結束（無資料）或 listen() 拋錯時：
+ if isReconnectEnabled, state == .connected || state == .handshakeDone {
+     try? await close()      // 先斷開（state 轉 .disconnected）
+     await startReconnection() // 再觸發底層重連 + resumePublishing
+ } else {
      try? await close()
+ }
```

`close()` → `startReconnection()` → `performConnect()` → `stream.resumePublishing()`，完整走底層既有重連流程。

**`BitRateStrategy.swift` `checkDisconnect` 無限觸發**

`checkDisconnect` 檢查 `lastStatusTimestamp` 超過 timeout 就呼叫 `onDisconnect`，每次觸發後無法自行停止。RTMP 斷線後每秒噴發。

→ 加入 `disconnectFired` flag，只觸發一次，重連成功後 `resetDisconnectCheck()` 重置。

## 附帶：`RTMPStream.swift` Task 包裝恢復

```
RTMPStream.swift:772

- let length = await conn.doOutput(...)
+ let length = await Task {
+     await conn.doOutput(...)
+ }.value
```

維持原先的 actor 隔離層級，避免因移除造成排程行為差異。
