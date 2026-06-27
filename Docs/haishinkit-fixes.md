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

## 附帶：`RTMPStream.swift` Task 包裝恢復

```
RTMPStream.swift:772

- let length = await conn.doOutput(...)
+ let length = await Task {
+     await conn.doOutput(...)
+ }.value
```

維持原先的 actor 隔離層級，避免因移除造成排程行為差異。
