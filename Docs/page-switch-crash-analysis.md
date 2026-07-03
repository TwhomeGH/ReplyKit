# 頁面切換崩潰修復：HaishinKit Buffer Overflow 導致 Swift String 記憶體損毀

## 現象

- 在日誌頁、音量頁、PIPChat 頁面之間切換時觸發崩潰
- crash 類型：`EXC_BAD_ACCESS/SIGSEGV`，`bug_type 309`
- fault address：`0x8`（nil 指標 + 8，PAC failure on ARM64e）
- 崩潰函數：`swift_isUniquelyReferenced_nonNull_native`

### Crash Stack（outer → inner）

```
completeTaskWithClosure                                   root
  → ??? (nearest symbol: LogMessage.encode +0x47)         data
  → ??? (nearest symbol: LogMessage.encode +0x43)         data
    → RTMPTimestamp.Error.hash(into:) +0xe3
      → VideoCaptureUnit.hasDevice +0x27
        → VideoCaptureUnit.attach.configuration +0x204
          → MediaMixer.stopRunning +0x210
            → swift_isUniquelyReferenced_nonNull_native   ← CRASH
```

## 根因

### 連鎖觸發路徑

```
使用者在音量/日誌頁來回切換
  → liveApp 透過 E-Socket 發送 onAudioPage/onlogPage / VideoReconfig
  → Extension 收到後呼叫 setVideoSettings / setAudioMixerSettings
    → HaishinKit 內部呼叫 MediaMixer.stopRunning()
      → HaishinKit C++ 程式碼發生 buffer overflow，破壞相鄰的 Swift heap
```

### 為什麼 crash 在 LogMessage 而不是 HaishinKit？

Swift 的 `String` 是 CoW（Copy-on-Write）型別，其 buffer 儲存在 heap 上。`LogManager` 將 log 字串暫存在 `localLogBuffer`（`[String]`）中，flush 時再複製到 `SocketClient.pendingBatchEntries`（也是 `[String]`）等待定時器 JSON 序列化。

當 HaishinKit 的 C++ buffer overflow 破壞了 heap 區域，受影響的 `String` 物件雖然外層 struct（指標 + 長度）完整，但其指向的 buffer metadata（refcount）已被覆寫為 0x0。後續 `JSONSerialization.data(withJSONObject:)` 在讀取此字串時，`swift_isUniquelyReferenced_nonNull_native` 嘗試讀取 refcount 時 crash。

### 時間窗口

```
sendlog("...")                  ← 字串建立，加入 localLogBuffer
  │   [等待 flush 定時器，最多 1 秒]
  v
flushLocalLogs()                ← 取出字串，送到 pendingBatchEntries
  │   [等待 batch 定時器，預設 250ms]
  v
flushBatch() → JSONSerialization ← 此處讀取字串 buffer，若已被 corrupt 則 crash
```

在這段時間內，任何其他 async Task 中的 `MediaMixer.stopRunning()` 都可能破壞 heap。

## 修改內容

### 1. `ReplyKIT/Event.swift` — `flushLocalLogs()`（主要修復）

在 `sendLogBatch` 之後立即呼叫 `forceFlushBatch()`，將 log 字串同步 JSON 序列化，消除 batch 定時器的等待窗口。

```swift
// Before
DispatchQueue.global(qos: .utility).async {
    SocketClient.shared.sendLogBatch(entries: bufferCopy)
}

// After
DispatchQueue.global(qos: .utility).async {
    SocketClient.shared.sendLogBatch(entries: bufferCopy)
    SocketClient.shared.forceFlushBatch()           // ← 立即序列化
}
```

`forceFlushBatch()` 使用 `queue.sync` 阻塞直到序列化完成，確保 JSON 封包建立後原始的 `String` buffer 不再被參照。

注意：此函數原先在 `forceFlush()` 中已有相同模式（`sendLogBatch` + `forceFlushBatch`），唯 `flushLocalLogs()` 遺漏。

### 2. `ReplyKIT/SampleHandler.swift` — Rotate handler

將 `sendlog` 呼叫移至 `setVideoSettings`（會觸發 `MediaMixer.stopRunning`）之前，讓 log 字串在 media operation 前就加入 buffer。

```swift
// Before
try await rtmpStream.setVideoSettings(vset)
RPConfig.shared.updateState(Rotate:Rlog)
sendlog(message:"[Rotate變換]  \(Rlog)")

// After
sendlog(message: "RVideoSET:\(vset)")
sendlog(message:"[Rotate變換]  \(Rlog)")         // ← 移到 media operation 之前
try await rtmpStream.setVideoSettings(vset)
RPConfig.shared.updateState(Rotate:Rlog)
```

### 3. `ReplyKIT/SampleHandler.swift` — `broadcastEnd()`

將 `sendlog` 從 `Task {}` 內部移到外部（Task 建立之前），確保 log 在 `mediaMixer.stopRunning()` 執行之前就安全進入 buffer。

```swift
// Before
func broadcastEnd(message: String) {
    Task {
        await mediaMixer.stopRunning()
        // ...
        sendlog(message:"[RTMP] \(message)")      // Task 內部，與 forceFlush 有 race
    }
    LogManager.shared.forceFlush()
}

// After
func broadcastEnd(message: String) {
    sendlog(message:"[RTMP] \(message)")          // ← 在 Task 之前執行

    Task {
        await mediaMixer.stopRunning()
        // ...
    }
    LogManager.shared.forceFlush()                // ← 立即 flush，字串已安全在 buffer
}
```

## 未來預防

1. **所有新 `Task {}` 中的 `sendlog` 應放在 `await` media operation 之前**
2. `flushLocalLogs()` 中 `sendLogBatch` 後應跟隨 `forceFlushBatch()`（已建立 project rule）
3. 若該特定 HaishinKit build 更新，可嘗試測試是否仍有相同 crash

## 相關檔案

| 檔案 | 行數 | 說明 |
|------|------|------|
| `ReplyKIT/Event.swift` | 392-395 | `flushLocalLogs` 加入 `forceFlushBatch` |
| `ReplyKIT/SampleHandler.swift` | 583-586 | Rotate handler 重排 `sendlog` 順序 |
| `ReplyKIT/SampleHandler.swift` | 1922-1963 | `broadcastEnd` 將 `sendlog` 移至 Task 外 |
