# ReplyKIT 日誌與 Socket 穩定性改進

## 1. 日誌文件行數上限

**文件**: `ReplyKIT/Event.swift:211, 415-427`  
**問題**: `writeLogToFile` 無限制追加，log.txt 持續膨脹。

**修復**:
- 新增 `maxLogFileLines = 5000` 行上限
- `writeLogToFile` 寫入後呼叫 `trimLogFileIfNeeded`，讀取全文、檢查行數、超過則保留最新 5000 行

```swift
private func trimLogFileIfNeeded(fileURL: URL) {
    guard let content = String(data: currentData, encoding: .utf8) else { return }
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count > maxLogFileLines else { return }
    let hasSuffixNewline = content.hasSuffix("\n")
    let trimmedLines = lines.suffix(maxLogFileLines)
    let trimmedText = trimmedLines.joined(separator: "\n") + (hasSuffixNewline ? "\n" : "")
    try? trimmedText.write(to: fileURL, atomically: true, encoding: .utf8)
}
```

## 2. `forceFlush` 限制 socket 發送量

**文件**: `ReplyKIT/Event.swift:296-311`  
**問題**: 切換到日誌頁時 `forceFlush()` 將全部累積日誌（可能數千行）經 socket 送出，造成伺服器端 10s send watchdog 超時斷線。

**修復**: socket 模式下只送最新 200 行：

```swift
if RPConfig.shared.enableSocketLog {
    let limited = bufferCopy.suffix(maxForceFlushLines)
    let text = limited.joined()
    SocketClient.shared.sendLog(title: "UseESocket", message: text)
}
```

## 3. Socket send timeout 10s → 30s

**文件**: `liveAPP/Socket.swift:1058`, `ReplyKIT/Socket.swift:847`  
**問題**: 10 秒 timeout 在大量日誌傳送時容易被誤觸，導致連線中斷。

**修復**: 兩端 timeout 皆提升至 30 秒。

| 位置 | 修改前 | 修改後 |
|------|--------|--------|
| `liveAPP/Socket.swift` (伺服器 send watchdog) | 10s | 30s |
| `ReplyKIT/Socket.swift` (客戶端 send timeout) | 10s | 30s |
