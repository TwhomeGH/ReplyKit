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

---

## Buffer Overflow 修復（2026-07）

### 背景

HaishinKit 內多處使用 `memcpy` 與 raw pointer arithmetic 時缺少 bounds check，C++-style buffer overflow 會破壞鄰近的 Swift String heap storage，導致在 log pipeline 中讀取已腐化的 String 時發生 `EXC_BAD_ACCESS`（pointer authentication failure）。最常見的觸發路徑：`setVideoSettings` / `stopRunning` 等媒體操作 → AudioRingBuffer 出界 → 相鄰 heap 上的 String buffer 被覆寫 → logQueue 處理日誌時 crash。

### `AudioRingBuffer.swift` — 音訊環形緩衝區

| 問題 | 原因 | 修正 |
|------|------|------|
| `head`/`tail` 無鎖，多執行緒同時讀寫 | AudioUnit render callback + CMSampleBuffer append 在不同佇列上操作同一組 count | 加入 `os_unfair_lock` 保護所有 `head`/`tail`/`skip`/`sampleTime` 讀寫 |
| `append(_:offset:)` 遞迴時 `offset` 可能讀取 source 緩衝區之外 | 遞迴 `offset` 遞增但 `frameLength` 不變，`advanced(by: offset * channelCount)` 可能超過 allocation | 檢查 `offset < frameLength`，超出直接 return；限制 `numSamples` 不超過剩餘空間 |
| `render()` 的 `memcpy` 使用 `outputBuffer.frameLength`（永久等於 capacity）計算剩餘空間 | `outputBuffer.frameLength` 設為 `frameCapacity` 後永不更新，`capacity - tail` 計算正確但有誤導性 | 改用 `outputBuffer.frameCapacity` 作為容量基準 |
| `render()` `memcpy` 使用 `advanced(by:)` 產生未檢查的 pointer | 若 `offset * channelCount * bytesPerSample` 為負或過大，寫入任意記憶體 | 統一計算 `copyBytes`，只對 `ioData` 和 source buffer 的有效範圍做 `memcpy` |
| 無 `numSamples > 0` guard | `0` 樣本的 `memcpy` 或 `memset` 雖不寫入但仍浪費 CPU | 加入 `guard numSamples > 0` |

```swift
// before: 無鎖、無 bounds check
memcpy(bufferList[0].mData?.advanced(by: offset * channelCount * 4),
       outputBuffer.floatChannelData?[0].advanced(by: tail * channelCount),
       numSamples * channelCount * 4)

// after: lock + 統一計算 + 雙向 guard
lock()
let copyBytes = numSamples * channelCount * bytesPerSample
guard let dst = bufferList[0].mData,
      let src = outputBuffer.int16ChannelData?[0].advanced(by: tail * channelCount) else { unlock(); return -1 }
memcpy(dst.advanced(by: offset * channelCount * bytesPerSample), src, copyBytes)
tail += numSamples
// ...
unlock()
```

### `CVPixelBuffer+Extension.swift` — 像素緩衝區複製

| 問題 | 原因 | 修正 |
|------|------|------|
| Non-planar 路徑 `bytesPerRowDst = bytesPerRowSrc`（永遠相等，永遠走 bulk path） | 沒有讀取 destination 的真實 bytesPerRow，bulk `memcpy` 若兩者實際 row stride 不同則寫出界 | `bytesPerRowDst = self.bytesPerRow`，只在 `bytesPerRowSrc == bytesPerRowDst` 時使用 bulk path |
| Bulk path 全量 `height * bytesPerRowSrc` 無限制 | 假設來源與目標尺寸一致 | 加入 `copyHeight = min(pixelBuffer.height, self.height)`、`copyWidth = min(bytesPerRowSrc, bytesPerRowDst)` |
| Planar 路徑相同問題 | 同上，且 `height` 變數遮罩了 destination plane height | `bytesPerRowDst = self.bytesPerRawOfPlane(plane)`、加入 `copyHeight`/`copyWidth` 限制 |

```swift
// before
let bytesPerRowDst = bytesPerRowSrc  // ← 永遠相等，永遠跳過 row-by-row 路徑
if bytesPerRowSrc == bytesPerRowDst {
    memcpy(dst, src, height * bytesPerRowSrc)  // ← 可能寫超過 dst 的實際 allocation
}

// after
let bytesPerRowDst = self.bytesPerRow          // ← 讀取真實 destination stride
let copyHeight = min(pixelBuffer.height, self.height)
let copyWidth = min(bytesPerRowSrc, bytesPerRowDst)
if bytesPerRowSrc == bytesPerRowDst {
    memcpy(dst, src, copyHeight * bytesPerRowSrc)
}
```

### `AVAudioPCMBuffer+Extension.swift` — 音訊緩衝區複製

| 問題 | 原因 | 修正 |
|------|------|------|
| `copy()` 只檢查 `frameLength == audioBuffer.frameLength`，沒檢查 `frameCapacity` | 若 `frameLength > frameCapacity`，`memcpy` 或 `update(repeating:)` 寫出界 | `numSamples = min(frameLength, audioBuffer.frameLength, frameCapacity, audioBuffer.frameCapacity)` |
| `muted()` 使用 `Int(frameLength)` 作為 `update(repeating:count:)` 的 count | 同上 | 改為 `min(Int(frameLength), Int(frameCapacity))` |

```swift
// before
guard frameLength == audioBuffer.frameLength else { return false }
let numSamples = Int(frameLength)

// after
let numSamples = min(Int(frameLength), Int(audioBuffer.frameLength),
                     Int(audioBuffer.frameCapacity), Int(frameCapacity))
guard numSamples > 0 else { return false }
```

### 受影響檔案

| 檔案 | 行數變化 |
|------|----------|
| `HaishinKit/Sources/Mixer/AudioRingBuffer.swift` | +150 (lock, bounds check, zeroBuffer helper, appendInternal rename) |
| `HaishinKit/Sources/Extension/CVPixelBuffer+Extension.swift` | +8 (bytesPerRowDst, copyHeight/copyWidth) |
| `HaishinKit/Sources/Extension/AVAudioPCMBuffer+Extension.swift` | +6 (frameCapacity guard) |
