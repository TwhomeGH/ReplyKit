# ReplyKIT 日誌與 Socket 穩定性改進

## 根本問題

原有 pipeline 在大量日誌時有三個連鎖缺陷：

1. **全部 flush、一次送**：`flushLocalLogs()` 把整個 buffer `joined()` 成一個巨大字串塞給 socket，單次 payload 可能數百 KB。socket 的 8KB chunking 產生 N 個 `{"type":"log"}` 排進 serial queue，最後面的 chunk 等幾十秒，30s watchdog 砍連線。

2. **沒有背壓（backpressure）**：LogManager 不知道 socket 吞不吞得下，一直 append 一直 flush，socket queue 無限堆積。queue 越長延遲越大，越容易 timeout。

3. **一個 timeout 就殺連線**：`sendPayload` 的 30s watchdog 不是跳過這筆，而是 `connection?.cancel()`，整條連線炸掉，所有 pending logs / control messages 全部遺失。

## 改造方案：Sliding-Window Batched Log Transport

### 1. Ring Buffer（固定容量）

**檔案**：`ReplyKIT/Event.swift:207-208`  
**改動**：`[String]` 無上限成長 → `maxRingBufferEntries = 1000`，超過時自動 `removeFirst()` 丟棄最舊的。

移除 byte-level 追蹤（`localLogSize`、`maxLogBufferSize`）和 size-based auto-flush，ring buffer 自動處理 overflow。

```swift
// before
self.localLogBuffer.append(logMessage)
self.localLogSize += logMessage.utf8.count
if self.localLogSize >= self.maxLogBufferSize {
    self.flushLocalLogs()
}

// after
self.localLogBuffer.append(logMessage)
if self.localLogBuffer.count > self.maxRingBufferEntries {
    self.localLogBuffer.removeFirst(self.localLogBuffer.count - self.maxRingBufferEntries)
}
```

### 2. Batched Log Send（bounded window）

**檔案**：`ReplyKIT/Socket.swift:748-842`  
**新機制**：

- `sendLogBatch(entries:)` 累積 entries 到 `pendingBatchEntries`
- 滿 50 條或 4KB 時打包送出，wire format：
  ```json
  {"type":"logbatch","entries":["line1","line2",...]}
  ```
- **Bounded send window**：最多 3 個 in-flight batches，超過時直接 drop 最舊的 batch（drop 數量 = min(pending, 50)）
- 250ms 定時器確保殘餘的 entries 不會永遠 pending
- 連線中斷時 entries 保留在 `pendingBatchEntries`，reconnect 後主動 flush

```swift
private func flushBatch() {
    guard inFlightBatches < maxInflightBatches else {
        // window 滿了，drop 最舊的 batch
        let dropCount = min(pendingBatchEntries.count, maxBatchEntries)
        pendingBatchEntries.removeFirst(dropCount)
        return
    }
    // 送出 batch
    _sendBatch(entries)
}
```

### 3. Server-side logbatch handler

**檔案**：`liveAPP/Socket.swift:970-974`  
新增 `case "logbatch"`，解出 entries 陣列後逐條餵給 `receiveSocketLog`：

```swift
case "logbatch":
    let batch = try decoder.decode(LogBatchPayload.self, from: data)
    for entry in batch.entries {
        receiveSocketLog(title: "UseESocket", message: entry)
    }
```

## 行為對照

| 場景 | 改前 | 改後 |
|------|------|------|
| 大量 log 產生 | buffer 衝到 100KB → 一整包 joined 送出 → socket timeout → 連線炸掉 → reconnect | ring buffer 自動 drop 最舊，batch 每包 ≤4KB，window 滿就 drop 舊 batch，連線穩定 |
| 繁忙時 socket 跟不上 | serial queue 無限堆積，越等越久 timeout | `maxInflightBatches=3` 硬限制，超過就 drop，保證 freshness |
| 控制訊息 | 被大型 log send 卡在 queue 後面 | log 走獨立 batch path，不影響 `sendPayload` 的其他 callers |
| forceFlush（終止時） | 200 行 joined 送出，fire-and-forget | 200 行 batch 送出 + `forceFlushBatch()` sync flush pending |
| 背景無日誌頁 | 100KB 靜默清空 buffer | ring buffer 自動管理，timer 觸發時 `removeAll()` |
| 連線中斷 | pendingLogs 暫存，reconnect 後全部 replay（可能再次塞車） | 連線不自動重連，下次操作 (requestSet/sendLogBatch) 時按需建立新連線 |

## 效能參數

| 參數 | 值 | 說明 |
|------|-----|------|
| `maxRingBufferEntries` | 1000 | 記憶體中最多保留 1000 條 log |
| `maxBatchEntries` | 50 | 每批最多打包 50 條 |
| `maxBatchBytes` | 4096 | 每批最大 4KB（避免觸發 send watchdog） |
| `maxInflightBatches` | 3 | 最多 3 批同時在飛，超過 drop 最舊 |
| batch timer | 250ms | 殘餘 entries 定時 flush |

## 4. 按需連線（On-Demand Socket）— 取代永久連線 + 自動重連

### 問題

主 App 被 iOS 殺後台後，SocketServer（port 9322）停止運行，但 Extension 端的 `SocketClient` 仍在背景不斷執行重連迴圈：

```
failed → retry() → backoff 2s → failed → retry() → backoff 4s → ...
→ circuitBreaker 5次後 60s cooldown → 再試 → 永遠失敗
```

每次重連耗費 CPU、DispatchQueue 資源、以及 Mach port 配額，卻永遠不會成功（伺服器不在運行）。即使主 App 事後重啟，Extension 也無法察覺，因為自動重連的指數退避已經卡在 30s 間隔，斷路器可能仍處於開啟狀態。

### 修正

移除所有自動重連基礎設施，改為**按需連線（on-demand connection）**：

| 被移除的元件 | 原因 |
|-------------|------|
| `retry()` + 指數退避（2s → 30s） | 伺服器不在時，重連永遠不會成功 |
| 斷路器（circuit breaker, 5次→60s cooldown） | 不需要 — 沒有重連就不需要斷路器 |
| 狀態機（SocketState: disconnected/connecting/connected/reconnecting/circuitBreakerOpen） | 連線生命周期簡化為「有 / 沒有」 |
| 心跳（heartbeat, 50s 間隔） | ❌ 已移除 — 按需連線不再需要發送心跳保活 |
| `onSocketReady` 回呼 | 不再需要 reconnect callback |
| `pendingLogs` + `flushPendingLogs()` | reconnect 不再存在，暫存無意義 |
| `sendReconnectStatus`（向 Server 回報重連狀態） | PiP 不再顯示 socket 重連狀態 |

### 新連線生命週期

每種「需要 socket」的場景各自管理自己的連線：

```
broadcastStarted() → connect() → requestRTMPKEYAndLog()
  → RTMP + LogConfig 回應抵達 → closeConnection()

requestSet(for: "onlogPage") → connect() → 發送 UPSet
  → UPSet 回應抵達 → closeConnection()

sendStreamEnd() → connect() → 發送 Ended
  → send 完成 → closeConnection()

flushBatch() (onLogPage=true 時) → connect() (若無連線) → 發送 logbatch
  → 保持連線供後續批次使用 → onLogPage=false 時 closeConnection()
```

### 性能與行為差異

| 面向 | 改前（永久連線 + 自動重連） | 改後（按需連線） |
|------|---------------------------|----------------|
| **背景被殺後台** | 永無止盡的重連迴圈（退避 + 斷路器），浪費 CPU 與 Mach port | 連線無聲斷開，Zero 背景活動 |
| **連線建立次數** | 1 次（broadcastStarted）+ N 次重連嘗試 | 每次操作建立一次（broadcastStart、broadcastEnd、每次 requestSet） |
| **log 串流延遲** | 連線已就緒，log batch 即時送達 | 首次 flushBatch 需等待連線建立（TCP localhost ~1-2ms），後續批次立即送達 |
| **requestSet 延遲** | 連線已就緒，立即發送 | 需建立新連線 + waitForReady (~1-5ms localhost TCP) |
| **sendStreamEnd 延遲** | 連線已就緒，立即發送 Ended | 需建立新連線 + 等待 ready (~1-5ms) |
| **CPU 開銷（背景）** | 重連嘗試 + 心跳\(已移除\) + circuit breaker timer | 零 |
| **連線可靠性** | 連線中斷後自動重連（但主 App 被殺後永遠失敗） | 不自動重連，下個操作按需建立新連線 |
| **PiP reconnect status** | Extension 向 Server 回報重連狀態 | 不再回報（Server 端 LPConfig.isReconnecting 維持 false） |

### 實作細節

- `connect()` 是冪等的：已有可用連線時直接返回，否則建立新 NWConnection
- `_connect()` 在 Serial Queue 上執行，確保與其他 socket 操作（sendPayload、flushBatch）的執行序正確
- `_closeConnection()` 清除所有 pending continuations，避免 async/await 洩漏
- Response handlers（`handleSingleJSONOnQueue`）在處理完回應後自動呼叫 `_closeConnection()`
- `cancelPending*()` 方法在取消請求後也會關閉連線

## 注意事項

- `sendLog`（單條 log 發送）保留不動，供 socket 內部 debug 訊息使用
- `forceFlushBatch()` 使用 `queue.sync` 確保 termination 前 pending batch 確實送出（內部呼叫 `_connect()` 確保連線存在）
- `closeConnection()` 重置 `inFlightBatches = 0` 並清空 `pendingBatchEntries`

---

## 5. 分屏／台前調度 Socket 連線修復（2026-07）

### 問題

在 iPadOS 的分屏（Split Screen）或台前調度（Stage Manager）模式下啟動直播時，Broadcast Extension 完全無反應。使用者回報「主 socket 又死了」。

### 根本原因

**SocketClient._connect() 對 NWConnection `.waiting` 狀態缺乏逾時處理：**

1. 主 App 的 SocketServer（NWListener）在分屏模式下可能因系統資源調度暫時不可用
2. Extension 的 `_connect()` 建立 NWConnection，但 server 不在監聽 → 連線進入 `.waiting`
3. `_connect()` 看到 `.waiting` 直接 `return`，**永遠不會重建連線**：
   ```swift
   // 改前：.waiting 也直接 return
   case .ready, .preparing, .waiting:
       return
   ```
4. `waitForReady()` 輪詢 10 秒 → 超時 → `requestRTMPKEYAndLog()` 失敗
5. 3 次重試共 ~45 秒後 → `stopBroadcastWithError()`
6. 使用者看到「完全沒反應」

**次要問題**：`cleanupStaleListener()` 會取消 `.preparing` 狀態的 listener，造成短暫的無監聽窗口。

### 修正

#### 5a. SocketClient：.waiting 逾時重建（`ReplyKIT/Socket.swift`）

新增 `connectionCreationTime` 追蹤連線建立時間，`.waiting` 超過 2 秒視為 server 不可用，關閉並重建連線：

```swift
private var connectionCreationTime: Date?
private let maxWaitTimeBeforeReconnect: TimeInterval = 2.0

// _connect() 中對 .waiting 的處理
case .waiting:
    if let creationTime = connectionCreationTime,
       Date().timeIntervalSince(creationTime) > maxWaitTimeBeforeReconnect {
        logTo("Connection waiting \(Int(...))s, recreating...")
        _closeConnection()
    } else {
        return
    }
```

`connectionCreationTime` 在連線建立時設為 `Date()`，在 `_closeConnection()` 與 `cleanupConnection()` 中清空。

#### 5b. SocketServer：保留 `.waiting` listener（`liveAPP/Socket.swift`）

`cleanupStaleListener()` 不再取消處於 `.waiting` 狀態的 NWListener（等候網路恢復時不應被打斷）：

```swift
case .waiting:
    logTo("listener 狀態 waiting，保留等待")
    isStopping = false
```

#### 5c. SocketServer：增強 ensureRunning（`liveAPP/Socket.swift`）

`ensureRunning()` 除了檢查 `listener == nil`，也檢查 listener 是否處於 `.failed` 狀態並觸發重啟：

```swift
if self.listener == nil {
    self.logTo("Listener missing, restarting")
    self.scheduleRestart(delay: 1.0)
} else if case .failed = self.listener?.state {
    self.logTo("Listener in failed state, restarting")
    self.stopInternal()
    self.start()
}
```

### 行為對照

| 場景 | 改前 | 改後 |
|------|------|------|
| 分屏啟動直播，server 忙碌 | NWConnection 卡 `.waiting` 直到 `waitForReady` 10s 超時，重試 2 次後放棄 | `.waiting` 逾 2s 自動重建連線，任一週期成功即繼續流程 |
| scene `.active` 時 listener 仍在 `.preparing` | `cleanupStaleListener()` 取消 listener 並重建，造成窗口損失 | listener 保留，等待自然就緒 |
| listener 進入 `.failed` 但未即時回收 | `ensureRunning()` 無反應（只檢查 nil） | 主動偵測 `.failed` 並觸發 restart |
