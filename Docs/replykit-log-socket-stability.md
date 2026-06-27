# ReplyKIT 日誌與 Socket 穩定性改進

## 根本問題

原有 pipeline 在大量日誌時有三個連鎖缺陷：

1. **全部 flush、一次送**：`flushLocalLogs()` 把整個 buffer `joined()` 成一個巨大字串塞給 socket，單次 payload 可能數百 KB。socket 的 8KB chunking 產生 N 個 `{"type":"log"}` 排進 serial queue，最後面的 chunk 等幾十秒，30s watchdog 砍連線。

2. **沒有背壓（backpressure）**：LogManager 不知道 socket 吞不吞得下，一直 append 一直 flush，socket queue 無限堆積。queue 越長延遲越大，越容易 timeout。

3. **一個 timeout 就殺連線**：`sendPayload` 的 30s watchdog 不是跳過這筆，而是 `connection?.cancel()` + `retry()`，整條連線炸掉，所有 pending logs / heartbeat / control messages 全部遺失。

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
| 心跳／控制訊息 | 被大型 log send 卡在 queue 後面 | log 走獨立 batch path，不影響 `sendPayload` 的其他 callers |
| forceFlush（終止時） | 200 行 joined 送出，fire-and-forget | 200 行 batch 送出 + `forceFlushBatch()` sync flush pending |
| 背景無日誌頁 | 100KB 靜默清空 buffer | ring buffer 自動管理，timer 觸發時 `removeAll()` |
| 連線中斷 | pendingLogs 暫存，reconnect 後全部 replay（可能再次塞車） | pendingBatchEntries 暫存，reconnect 後 flush，單批 ≤4KB |

## 效能參數

| 參數 | 值 | 說明 |
|------|-----|------|
| `maxRingBufferEntries` | 1000 | 記憶體中最多保留 1000 條 log |
| `maxBatchEntries` | 50 | 每批最多打包 50 條 |
| `maxBatchBytes` | 4096 | 每批最大 4KB（避免觸發 send watchdog） |
| `maxInflightBatches` | 3 | 最多 3 批同時在飛，超過 drop 最舊 |
| batch timer | 250ms | 殘餘 entries 定時 flush |

## 注意事項

- `sendLog`（單條 log 發送）保留不動，供 socket 內部 debug 訊息使用（如 "Socket connected"）
- `forceFlushBatch()` 使用 `queue.sync` 確保 termination 前 pending batch 確實送出
- `closeConnection()` 重置 `inFlightBatches = 0` 並清空 `pendingBatchEntries`，避免 reconnect 後狀態不一致
