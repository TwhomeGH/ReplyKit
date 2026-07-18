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

---

## 6. Keepalive 強化與死連線檢測（2026-07）

### 問題

1. **Keepalive 30s 間隔過長**：iOS 可能在 30s 內 suspend extension，server 無法及時發現連線死亡。連線死後 keepalive 繼續往 dead socket 寫入，30s send timeout 才清理。
2. **用戶端心跳與 server keepalive 碰撞**：原先加入了用戶端主動每 10s 發送 heartbeat 的機制，但用戶端同時也會被動回應 server 的 `keepalive`。兩者每 10s 撞車導致 server 收到重複的心跳包，浪費頻寬且增加 send timeout 誤判風險。（已移除用戶端主動心跳，改為純被動回應）
3. **聊天訊息與觀眾人數更新耦合**：extension 僅需更新人數時被迫發送一整個 `StreamMessage`（含空 user/msg），增加解析成本與頻寬浪費。

### 修正

#### 6a. Keepalive 間隔縮短至 10s（`liveAPP/Socket.swift`）

```swift
// 改前
timer.schedule(deadline: .now() + 30, repeating: 30)

// 改後
timer.schedule(deadline: .now() + 10, repeating: 10)
```

#### 6b. ❌ 用戶端主動心跳（已移除 `ReplyKIT/Socket.swift`）

~~連線建立後啟動 10s 定時器，主動發送 `{"type":"heartbeat"}`~~  
已移除：用戶端不再主動發送 heartbeat，僅被動回應 server 的 `keepalive`。  
原因：server 每 10s 發送 `keepalive`，用戶端每 10s 又主動發 `heartbeat`，兩者碰撞導致 server 收到重複心跳，浪費頻寬且增加 send timeout 誤判風險。Server 端 `lastReceiveTime` 60s 逾時機制已足夠檢測死連線。

#### 6c. 伺服器端 stale 連線檢測（`liveAPP/Socket.swift`）

追蹤每條連線的最後接收時間，keepalive 發送前檢查：

```swift
private var lastReceiveTimes: [ObjectIdentifier: Date] = [:]
private let staleConnectionTimeout: TimeInterval = 60

// sendKeepalive() 中
for (id, conn) in connections {
    if let lastRx = lastReceiveTimes[id],
       now.timeIntervalSince(lastRx) > staleConnectionTimeout {
        logTo("Connection stale, removing")
        removeConnection(conn)
        continue
    }
    sendTo(conn, payload: payload)
}
```

`lastReceiveTimes[id]` 在連線建立時初始化為 `Date()`，每次 `runReceiveLoop` 收到資料時更新，在 `removeConnection`/`stopInternal`/`suspend`/`releaseMemory` 中清理。

#### 6d. 獨立 AudienceUpdate 訊息類型

Server 端新增輕量解析器，僅更新人數不處理聊天渲染：

```swift
struct AudiencePayload: Codable {
    let userNum: Int?
    let userList: [String]?
}

case "audience":
    let dict = try decoder.decode(AudiencePayload.self, from: data)
    updateAudienceInfo(userNum: dict.userNum, userList: dict.userList)
```

### 行為對照

| 場景 | 改前 | 改後 |
|------|------|------|
| 連線死亡但 NWConnection 未偵測 | 30s keepalive 繼續往死連線寫，30s send timeout 才清理 | 10s keepalive + 60s 無資料閾值，最多 70s 檢測到 dead 連線並移除 |
| extension 被 iOS suspend 後恢復 | 無主動心跳，server 空等 30s 才發現連線可能死亡 | server 10s keepalive 觸發 extension 回應 heartbeat，立即更新 lastReceiveTime |
| 僅更新觀眾人數 | 發送完整 `StreamMessage`（含空 user/msg），server 解析 ChatMessage 全部欄位 | 發送輕量 `audience`（僅 userNum/userList），server 輕量解析 |
| 心跳碰撞 | 無（改前無用戶端主動心跳） | ~~用戶端主動心跳 + keepalive 回應雙重發送，造成重複~~ 已移除用戶端主動心跳，純被動回應 |

---

## 7. Send 基礎設施 Codable 遷移（2026-07）

### 動機

原本所有 socket payload 都用 `[String: Any]` + `JSONSerialization`：
- 編譯器無法檢查 key 名稱或型別正確性
- payload 建構與解析不一致（server 發送用 dictionary、接收用 Codable struct）
- `JSONSerialization` 對 `Any` 的處理拋棄型別安全

### 改動

#### 7a. Send queue 型別變更（`liveAPP/Socket.swift`）

```swift
// 改前
private var sendQueues: [ObjectIdentifier: [[String: Any]]] = [:]

// 改後
private var sendQueues: [ObjectIdentifier: [Data]] = [:]
```

queue 不再儲存未序列化的 dictionary，改存已編碼的 `Data`。序列化在 `enqueue` 前完成。

#### 7b. 新增 `Encodable` 版本的 send 函數

```swift
/// 對 Sendable payload 編碼後入隊
private func encodedData<T: Encodable>(_ payload: T) -> Data? {
    try? JSONEncoder().encode(payload)
}

/// Encodable 版本 — 類型安全的 payload 建構
private func sendTo(_ connection: NWConnection, payload: some Encodable) {
    guard let data = encodedData(payload) else { return }
    enqueue(data, to: connection)
}

/// 群播也使用 Encodable
func queueSend(payload: some Encodable) {
    guard let data = encodedData(payload) else { return }
    queue.async {
        for conn in self.connections.values {
            self.enqueue(data, to: conn)
        }
    }
}
```

#### 7c. 新舊共存（逐步遷移）

`broadcast` 與 `GetRTMPConfig()` / `GetLogConfig()` 等回傳 `[String: Any]` 的函數保留不動，使用保留的 dictionary → Data 輔助方法：

```swift
private func sendTo(_ connection: NWConnection, dictionary: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: []) else { return }
    enqueue(data, to: connection)
}
```

#### 7d. sendNextPayload 簡化

```swift
// 改前：收到 dictionary 後才做 JSONSerialization
let payload = queue.removeFirst()
guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { ... }
var dataWithNewline = data
dataWithNewline.append(0x0A)

// 改後：data 已預先編碼，只需補 newline
var data = queue.removeFirst()
data.append(0x0A)
```

### 影響

| 面向 | 改前 | 改後 |
|------|------|------|
| Payload 建構 | `["type": "keepalive"]` (untyped) | `KeepaliveMessage()` (typed struct) |
| 序列化 | `JSONSerialization.data(withJSONObject:)` | `JSONEncoder().encode(_:)` |
| 發送 queue 型別 | `[[String: Any]]` | `[Data]` |
| 編譯器檢查 | 無（key 拼錯 runtime 才炸） | 有（struct 不存在就無法編譯） |
| 逐步遷移 | — | 保留 dictionary overload，可逐一轉換 |

---

## 8. 停用 Quality 位元率模式（2026-07）

### 問題

BitRateMode 選項 3（Quality）會啟用 `videoSettings.bitRateMode = .quality`，在 HaishinKit 中此模式無視設定位元率、改以畫面品質為目標，導致直播位元率暴衝或異常偏低。使用 HEVC 編碼時即使選擇 ABR/CBR 也會被強制轉為 VBR（見 `SampleHandler.swift:1336-1339`），但 Quality 模式不受此保護。

### 修正

| 檔案 | 改動 |
|------|------|
| `liveAPP/Setting.swift` | `BitRateOptions` 陣列從 4 項減為 3 項，移除「Quality 品質模式」 |
| `ReplyKIT/SampleHandler.swift` | switch 前 `min(BitRateMode, 2)`，值 3 自動降級為 2 (VBR) |
| `liveAPP/Socket.swift` | `GetRTMPConfig()` 輸出時 clamp `BitRateMode` 到 0-2 |
| `ReplyKIT/Socket.swift` | `applyRTMP()` 套用時 clamp `c.BitRateMode` |
| `ReplyKIT/Event.swift` | `updateState()` 儲存時 clamp |

### 行為對照

| 情境 | 改前 | 改後 |
|------|------|------|
| 使用者先前選了 Quality（UserDefaults 存 3） | 啟用 `.quality`，位元率失控 | 自動降級為 VBR (2) |
| HEVC + ABR/CBR | 強制轉 VBR，但 Quality 維持不變 | 已無 Quality 選項，HEVC 統一走 VBR |
| Picker 顯示 | 4 個 segment | 3 個 segment（Quality 移除） |

---

## 9. 移除 Send Timeout 主動斷線機制（2026-07）

### 問題

`sendNextPayload()` 中有一個 30s 計時器：若 `conn.send` 的 `.contentProcessed` callback 在 30s 內未觸發，server 會主動呼叫 `removeConnection()` 砍掉連線。

但 NWConnection callback 在 iOS 高負載或 app 狀態切換時可能遺失（見 #244 分析）。此時連線**接收端完全正常**（heartbeat 仍可送達），僅因 send callback 未觸發就被 server 主動斷線，反而破壞穩定性。

### 修正

移除 send timeout 計時器與 `sendTimeoutFlags`，完全交由 NWConnection 自己管理連線生命週期：

```swift
// 改前：30s 計時器 + 強制 removeConnection
let timeoutKey = "send_\(id)"
sendTimeoutFlags[timeoutKey] = true
queue.asyncAfter(deadline: .now() + 30) { [weak self, weak conn] in
    guard let self, let conn else { return }
    guard sendTimeoutFlags.removeValue(forKey: timeoutKey) != nil else { return }
    logTo("Send timeout, removing connection")
    removeConnection(conn)
}

conn.send(content: data, completion: .contentProcessed { error in
    sendTimeoutFlags.removeValue(forKey: timeoutKey)
    // ...
})

// 改後：僅靠 send completion callback 驅動 queue
conn.send(content: data, completion: .contentProcessed { [weak self] error in
    guard let self = self else { return }
    if let error {
        removeConnection(conn)   // NWConnection 回報錯誤才斷
        return
    }
    sendNextPayload(for: conn)   // 正常完成就送下一筆
})
```

### 影響

| 面向 | 改前 | 改後 |
|------|------|------|
| Send callback 遺失 | 30s 後 server 主動砍連線 | 連線保留，下一筆 keepalive/send 會觸發新 callback |
| 連線穩定性 | 健康連線被誤殺 → Node.js bot 需 15s 重連 | 健康連線不受影響，僅 NWConnection 回報 error 才斷 |
| 死連線偵測 | 30s send timeout（過度積極） | 60s stale connection timeout（keepalive 時檢查 lastReceiveTime） |

---

## 10. PiP 保活模式（2026-07）

### 動機

PiP（子母畫面）能讓 iOS 在背景保持 app 存活，但標準 PiP 以 4-24 fps 持續渲染畫面，耗電且對長時間純監控場景無必要。新增一個「保活模式」：極低幀率、無聊天訊息渲染、僅顯示時間與狀態，用最少資源維持 PiP 活躍。

### 實作

**新增屬性**（`liveAPP/PIPService.swift`）：

```swift
private(set) var isKeepaliveMode = false
private let keepaliveFPS: Double = 0.1    // 每 10 秒 1 幀
```

**`startKeepalivePiP()`** —— 類似 `startPiP()` 但不建立 `messagesLayer`，`currentFPS` 直接鎖 `keepaliveFPS`。

**`decayFPSIfNeeded()`** 開頭檢查：

```swift
guard !isKeepaliveMode else {
    if abs(currentFPS - keepaliveFPS) > 0.01 { currentFPS = keepaliveFPS }
    return
}
```

**`renderUIViewToPixelBuffer()`** 跳過聊天渲染：

```swift
if !isKeepaliveMode {
    messagesLayer?.container.render(in: context)
}
```

**`drawTimeOverlay()`** 在保活模式顯示兩行：

```
┌──────────────────────────┐
│   2026/07/15 下午05:10:30  │  ← 白色 monospacedDigit 16
│   保活用子母工作中          │  ← 綠色 bold 18
└──────────────────────────┘
```

兩行水平居中，黑色半透明背景 0.6 alpha。

**UI 按鈕**（`liveAPP/PIPContent.swift`）：

```
[聊天組]啟動 PiP    [保活組]啟動 PiP 保活    [聊天室]停止 PiP
```

### 行為對照

| 面向 | 標準 PiP | 保活 PiP |
|------|----------|----------|
| 幀率 | 4-24 fps（動態調整） | 0.1 fps（固定） |
| 聊天訊息 | 渲染 + 動畫 | 不渲染 |
| 畫面內容 | 時間 + 狀態 + 聊天訊息 | 時間 + 「保活用子母工作中」 |
| 耗電 | 高（持續 CPU/GPU） | 極低 |
| 目的 | 直播監控 + 聊天互動 | 純保活（避免 iOS 殺後台） |
| 停止 | 同一 `stopPiP()` | 同一 `stopPiP()` |

---

## 11. Audio/Video 管線優先級修正（2026-07）

### 問題

Audio/Video 處理管線的 `Task.detached(priority: .utility)` 是音訊斷斷續續的**唯一原因**。

iOS 的 GCD / Swift Concurrency 優先級系統中，`.utility` 是**背景級別**——系統在有更高優先級工作（UI、網路、使用者互動）時，會大幅延遲 `.utility` task。Audio 每 ~20ms 就需要處理一個 buffer，若被延遲 50-100ms 就會造成可感知的斷音。

原本的架構設計是正確的：
- 每幀獨立 `Task.detached`（不互相等待，不會整條鏈卡死）
- `isProcessing` guard 在忙碌時自動丟棄重疊幀（對視訊正確，對音訊偶爾丟一幀也無感）
- Actor 內部 `isProcessing` 防止 GPU 旋轉重疊

唯一需要改的只有優先級。

### 修正

```swift
// 改前
Task.detached(priority: .utility) { ... }

// 改後
Task.detached(priority: .high) { ... }
```

`.high` 是使用者啟動級別，與 UI 互動、網路響應同等優先，系統不會隨意延遲。

### 為什麼不是其他設計

| 嘗試過的方案 | 問題 |
|------------|------|
| `Task chain`（prev?.value） | 一個 task 卡死即整條鏈停擺 |
| `cancel + restart` | 永遠沒 task 能完成（新 task 取消前一個，前一個永遠送不到 MediaMixer） |
| `DispatchQueue + semaphore` | blocking serial queue thread，造成 thread 耗盡 |
| 移除 `isProcessing` guard | 多個 GPU 旋轉同時進行（actor 會保護，但旋轉結果可能被跳過） |

`Task.detached(priority: .high)` + `isProcessing` guard 是最穩定的方案——每個 task 獨立執行不互相阻塞，忙碌時自然丟幀，不引入任何新的 deadlock 風險。

### 行為對照

| 面向 | 改前 (.utility) | 改後 (.high) |
|------|-----------------|--------------|
| 優先級 | 背景級，可被大幅延遲 | 使用者級，即時處理 |
| task 互相影響 | 獨立，不互相等待 | 同左（不變） |
| 忙碌時 | `isProcessing` guard 丟棄多餘幀 | 同左（不變） |
| 音訊斷續風險 | 高 | 低 |
| 程式碼變動量 | — | 2 字串（`.utility` → `.high`） |
| 已處理總行數變動 | Audio: -88 行，Video: -136 行 | — |


---

## 12. 設定頁面來回切換卡死（2026-07）

### 問題

使用者在「主設定」sheet 內，於音訊處理 / PIP 設置 / GPU 旋轉設置等 NavigationLink 頁面快速來回切換時，應用卡死。

### 根因：四項連鎖問題

#### 12a. DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) 競態窗口

Tab 切換時透過 DispatchWorkItem 延遲 0.3s 才更新 @AppStorage，但 PageState 的 Combine .sink 立即更新 @Published 變數。兩者不一致的 0.3s 窗口內若發生 scenePhase 變更，scenePhase handler 會偵測到不匹配而重複發出 CFNotification，造成連鎖狀態更新和 Layout 迴圈。

#### 12b. PageState Combine .sink 重複邏輯

與 .onChange(of: pageState.currentPage) 做完全相同的事，但執行在不同時間點（sink 立即、onChange 延遲 0.3s）。

#### 12c. @StateObject gpuSettings 每次 sheet 打開重建

每次使用者打開設定 sheet，就建立新的 GPUSettingsViewModel，其 init() 執行 JSON decode + 8 次 @AppStorage 寫入，全部在 main thread。

#### 12d. TextField + Stepper 雙重 .onChange

每個 PIP 設定的 TextField 和 Stepper 各自掛載 .onChange(of:) 處理器，修改一次值觸發兩次 logTo() + LPConfig.shared.* = newVal。

### 修正

| # | 問題 | 修正 |
|---|------|------|
| 12a | 0.3s 延遲 DispatchWorkItem | 移除延遲，切換頁時同步更新 @AppStorage + pageState.@Published + CFNotification |
| 12b | Combine.sink 重複 | 移除 .sink——.onChange handler 直接設定 pageState.onAudioPage/onlogPage |
| 12c | @StateObject gpuSettings | 改為 static let shared singleton + @ObservedObject，init 只跑一次 |
| 12d | TextField + Stepper 雙重 onChange | 每項只保留一個 .onChange，移除 TextField 端的重複 handler |

### 行為對照

| 面向 | 改前 | 改後 |
|------|------|------|
| 頁面切換延遲 | 0.3s (asyncAfter) | 即時 |
| @AppStorage vs @Published 同步 | 可能不一致 0.3s | 同步更新 |
| 每項設定 onChange 觸發次數 | 2 次 (TextField + Stepper 各 1) | 1 次 |
| gpuSettings 建立次數 | 每次 sheet 打開 | 1 次 (singleton) |
| 來回切頁卡死 | 會 | 不會 |
