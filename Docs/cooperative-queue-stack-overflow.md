# Cooperative Queue Stack Overflow (bug_type 309)

## 最終根因

**`Task(priority:)` 的 QoS 決定了 actor executor 使用的 thread pool。**

```
broadcastStarted Task → priority: userInitiated (預設)
  └─ 呼叫 HaishinKit actor methods
       └─ actor executor 繼承 userInitiated QoS
            └─ 分配到 com.apple.root.user-initiated-qos.cooperative (544KB stack)
                 └─ 內部 Task { } 繼承 cooperative executor
                      └─ 💥 Stack Overflow
```

### 關鍵誤解

| 誤解 | 事實 |
|------|------|
| `Task { }` 會繼承 cooperative queue | 取決於**呼叫端的 QoS**，不是固定的 |
| `Task.detached` 可以脫離 cooperative | `Task.detached(priority: .userInitiated)` 仍對應 cooperative pool |
| actor executor 不受 QoS 影響 | actor 的 default executor 從 global pool 取 thread，QoS 由 caller 決定 |
| HaishinKit actor 內部 `Task { }` 安全 | actor executor 本身可能跑在 cooperative thread 上 |

---

## 解法

### `Task(priority: .utility) { }` — 僅改 QoS，保留 actor context

```swift
// ❌ 預設 priority = userInitiated → cooperative pool (544KB)
Task {
    await mediaMixer.startRunning()  // actor executor 用 cooperative thread
}

// ✅ priority = utility → utility pool (~1MB)，self. 照常可用
Task(priority: .utility) {
    await mediaMixer.startRunning()  // actor executor 用 utility thread
}
```

`Task(priority:)` 只改變 QoS class，**不破壞 actor context**（`self.` 不需顯式宣告）。整個呼叫鏈的 QoS 被繼承，HaishinKit actor 內部所有 `Task { }` 都跑在 utility pool。

### `Task.detached(priority: .utility)` — 僅用於非 actor class 的 per-frame 處理

VideoProcess / AudioProcess 是非 actor class，需要 `Task.detached` 來脫離 cooperative（因為 `processSampleBuffer` callback 本身就可能是 cooperative thread）。

---

## Crash 時間線（2026-06-24）

| 時間 | slice_uuid | 嘗試 | 結果 |
|------|-----------|------|------|
| 15:58 | `eb6a822b` | 原始程式碼 | Crash |
| 16:32 | `43e0a1af` | Video/Audio → `Task.detached(.userInitiated)` | Crash |
| 17:08 | `43e0a1af` | 同上（SampleHandler 還原） | Crash |
| 17:35 | `8c874ad2` | FrameGate 移除，`isProcessing` guard | Crash |
| 18:04 | `0db57c02` | `.userInitiated` → `.utility`（Video/Audio） | Crash |
| 最終 | — | **`broadcastStarted` → `Task(priority: .utility)`** | ✅ |

---

## 技術細節

### QoS ↔ Thread Pool 對照（iOS 27 Beta）

| QoS | Thread Pool | Stack |
|-----|------------|-------|
| `.userInitiated` | `com.apple.root.user-initiated-qos.cooperative` | 544KB |
| `.utility` | `com.apple.root.utility-qos` | ~1MB |
| `.default` | `com.apple.root.default-qos` | ~1MB |
| `.background` | `com.apple.root.background-qos` | ~1MB |

### `Task` 變體對照

| | `Task { }` | `Task(priority:) { }` | `Task.detached(priority:) { }` |
|---|---|---|---|
| Actor context | 繼承 | **繼承** | 不繼承 |
| QoS | 繼承 caller | **指定** | 指定 |
| @Sendable | 否 | 否 | **強制** |
| self. 要求 | 否 | **否** | **是**（Swift 6） |
| 適用場景 | 一般 | **actor 呼叫鏈 QoS 控制** | per-frame 非 actor 處理 |

### 不要改 actor 內部

Actor（`RTMPConnection`, `RTMPStream`, `MediaMixer` 等）內部 `Task { }` 跑在 actor 自己的 serial executor 上。只要確保 **呼叫 actor 的 QoS** 不是 `.userInitiated`，actor executor 就不會用 cooperative thread。

---

## Crash 特徵

| 欄位 | 值 |
|------|-----|
| bug_type | `309`（Stack Overflow） |
| 例外 | `EXC_BAD_ACCESS` / `SIGBUS` / `KERN_PROTECTION_FAILURE` |
| 崩潰位址 | Stack Guard 區域（`bytes after start: 16368, bytes before end: 15`） |
| 崩潰 Queue | `com.apple.root.user-initiated-qos.cooperative` |
| Stack 大小 | 544KB（已用盡，撞到 guard page） |
| 發生時機 | 推流啟動後 ~350-500ms |
| iOS 版本 | iOS 27.0 Beta (24A5370h) |

---

## 潛在風險

### 1. 第三方 Library 的 `Task { }` 風險

任何 Swift library 若在 `userInitiated` QoS context 中被呼叫，其內部 `Task { }` 都會繼承 cooperative pool。Library 作者無法控制呼叫端的 QoS，因此：
- 對呼叫端：用 `Task(priority: .utility)` 隔離第三方 code
- 對 library 作者：內部用 `Task.detached(priority: .utility)` 避免依賴呼叫端 context

### 2. `DispatchSemaphore` 在 Swift Concurrency 中的風險

`DispatchSemaphore.wait()` 會阻塞 cooperative thread，導致 pool 縮小、其他 task 堆積、stack 壓力增加。應改用 actor 序列化或 `AsyncSemaphore`。

### 3. Actor executor 的 QoS 繼承

Actor 的 default serial executor 從 global concurrent pool 取 thread，QoS 由呼叫端決定。這是設計行為而非 bug，但 iOS 27 beta 的 cooperative pool stack 限制（544KB）讓這個行為變得危險。

---

## 受影響檔案

| 檔案 | 修改 |
|------|------|
| `ReplyKIT/SampleHandler.swift` | `broadcastStarted` 的 `Task { }` → `Task(priority: .utility)`；rtmpConnection/rtmpStream 從 `init()` 移到 socket config 後建立 |
| `ReplyKIT/VideoProcess.swift` | `Task { }` → `Task.detached(priority: .utility)`；`isProcessing` guard 取代 FrameGate |
| `ReplyKIT/AudioProcess.swift` | `Task { }` → `Task.detached(priority: .utility)` |
| `.github/workflows/main.yml` | `workflow_run` → `push tags` 觸發 |
