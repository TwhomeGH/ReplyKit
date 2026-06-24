# Cooperative Queue Stack Overflow (bug_type 309)

## 問題

`VideoFrameProcessor.process()` 與 `AudioProcessor.enqueue()` 內部使用 `Task { }` 建立 unstructured task。在 iOS 27 beta 上，`Task { }` 會繼承呼叫端的 executor context，導致所有幀處理任務被派發到 `com.apple.root.user-initiated-qos.cooperative` queue。

Cooperative queue 的 thread stack 僅 **544KB**，而每幀 video 處理路徑有 4 層 actor hop + `withCheckedContinuation` GPU 等待，累積後超出 stack 上限，觸發 stack guard page → `SIGBUS`。

### Crash 特徵

| 欄位 | 值 |
|------|-----|
| bug_type | `309`（Stack Overflow） |
| 例外 | `EXC_BAD_ACCESS` / `SIGBUS` / `KERN_PROTECTION_FAILURE` |
| 崩潰位址 | Stack Guard 區域內（`0x16dddbff0`） |
| 崩潰 Queue | `com.apple.root.user-initiated-qos.cooperative` |
| Stack 大小 | 544KB（已用盡） |
| 發生時機 | 推流啟動後數秒內 |
| iOS 版本 | iOS 27.0 Beta (24A5370h) |

### 觸發路徑

```
processSampleBuffer (ReplayKit 每幀回呼, 30-60 fps)
  └─ VideoFrameProcessor.process()
       └─ Task { }                              ← 繼承 cooperative executor
            └─ ProcessorActor.processFrame()    ← actor hop 1
                 └─ getOrCreateRotator()        ← actor hop 2
                      └─ rotateAsync()          ← actor hop 3
                           └─ ensureMetalResources()
                           └─ getReusableOutput()
                           └─ renderPlaneYUV()
                           └─ withCheckedContinuation { }  ← suspension 4
                                └─ wrapPixelBuffer()
                                └─ tsDebugger.log()
            └─ mediaMixer.append()              ← actor hop 5
```

每一幀 = **5 層 actor/continuation suspension**，全部壓在同一個 544KB stack 的 cooperative thread 上。

### 與其他 Stack Overflow 的差異

| 類型 | 原因 | 觸發時機 |
|------|------|----------|
| NWConnection 遞迴 | callback 內同步呼叫 `receive()` | Socket 大量資料交換 |
| 泛型特化遞迴 | `withUnsafeBytes<UInt32>` 編譯器特化 | ByteArray 讀取 |
| 協程幀遞迴 | `__swift_coroFrameAllocStub` + Metal async | GPU pipeline 初次建立 |
| **Cooperative Queue** | **`Task { }` 繼承 cooperative executor，actor hop 過深** | **每幀處理** |

---

## 影響原因

### 為什麼 cooperative queue stack 特別小？

iOS 的 Swift concurrency runtime 對不同 QoS 的 executor 有不同 stack 配置：

- **Cooperative queue** (`user-initiated-qos.cooperative`)：544KB — 設計給輕量、短暫的 cooperative task，不預期深層 actor 呼叫鏈
- **Global concurrent executor**：預設 ~1MB+ — 一般 async task 使用

### 為什麼 `Task { }` 會進 cooperative queue？

`Task { }` 是 **unstructured task**，會繼承當前 `Task` 的 executor context。由於 `processSampleBuffer` 是由 ReplayKit 在一個已綁定 cooperative executor 的 context 中呼叫，內部 `Task { }` 也繼承了這個 executor。

### 為什麼 actor hop 會耗 stack？

每次 `await actor.method()` 都是一個 suspension point。Swift runtime 在 cooperative thread 上處理這些 suspension 時，continuation 的 resume 會在同一個 stack 上累積。5 層 actor hop + `withCheckedContinuation` = 同一 thread 上至少 5 次 stack frame 堆疊。

---

## 修復方式

### 核心修改

將 `Task { }` 改為 `Task.detached(priority: .userInitiated) { }`：

```swift
// ❌ 危險：繼承 cooperative executor，stack 僅 544KB
func process(_ sampleBuffer: CMSampleBuffer, oringinaltime: CMSampleTimingInfo) {
    Task { [weak self] in
        await self?.processorActor.processFrame(...)
        await self?.mediaMixer.append(...)
    }
}

// ✅ 安全：detached task 使用 global concurrent executor，stack 充足
func process(_ sampleBuffer: CMSampleBuffer, oringinaltime: CMSampleTimingInfo) {
    Task.detached(priority: .userInitiated) { [weak self] in
        await self?.frameGate.enter()
        defer { self?.frameGate.exit() }
        await self?.processorActor.processFrame(...)
        await self?.mediaMixer.append(...)
    }
}
```

### 新增 FrameGate 並行控制

因為 `Task.detached` 不再受限於 cooperative queue 的序列化特性，需加入 `FrameGate` 限制同時處理的幀數上限為 2，避免 GPU 管線堆積：

```swift
private final class FrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private let maxConcurrent: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async { /* 超過上限時 await 等待 */ }
    func exit() { /* 釋放 slot，喚醒等待者 */ }
}
```

### 關鍵差異

| 項目 | 修正前 | 修正後 |
|------|--------|--------|
| Task 類型 | `Task { }` (inherited executor) | `Task.detached(priority:)` (global executor) |
| Executor | cooperative (544KB stack) | global concurrent (~1MB+ stack) |
| 並行控制 | 無（依賴 cooperative 序列化） | `FrameGate(max: 2)` |
| Stack 溢位風險 | **高**（每幀 5 層 actor hop） | **低**（stack 空間充足） |

---

## 受影響檔案

| 檔案 | 修改內容 |
|------|----------|
| `ReplyKIT/VideoProcess.swift` | `Task { }` → `Task.detached`，新增 `FrameGate` 限制並行幀數 |
| `ReplyKIT/AudioProcess.swift` | `enqueue()` 內 `Task { }` → `Task.detached` |
