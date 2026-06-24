# Cooperative Queue Stack Overflow (bug_type 309)

## 問題概述

在 iOS 27.0 Beta 上，ReplyKIT extension 啟動後 ~400ms 內 crash，所有崩潰都是 `bug_type: 309`（Stack Overflow）。

### Crash 特徵

| 欄位 | 值 |
|------|-----|
| bug_type | `309`（Stack Overflow） |
| 例外 | `EXC_BAD_ACCESS` / `SIGBUS` / `KERN_PROTECTION_FAILURE` |
| 崩潰位址 | Stack Guard 區域（`bytes after start: 16368, bytes before end: 15`） |
| 崩潰 Queue | `com.apple.root.user-initiated-qos.cooperative` |
| Stack 大小 | 544KB（已用盡，撞到 guard page） |
| 發生時機 | 推流啟動後 ~350-500ms |
| iOS 版本 | iOS 27.0 Beta (24A5370h) |

### Crash 時間線（2026-06-24）

| 時間 | slice_uuid | 修正內容 | 結果 |
|------|-----------|----------|------|
| 15:58 | `eb6a822b` | 原始程式碼 | Crash |
| 16:32 | `43e0a1af` | VideoProcess + AudioProcess → `Task.detached(.userInitiated)` | **仍 Crash** |
| 17:08 | `43e0a1af` | 同上（SampleHandler 還原） | **仍 Crash**（同 binary） |
| 17:35 | `8c874ad2` | 移除 DispatchSemaphore FrameGate，改用 `isProcessing` guard | **仍 Crash** |
| 18:04 | `0db57c02` | `.userInitiated` → `.utility` | **仍 Crash** |

五次修正都失敗 → 問題不在 ReplyKIT 自己的 code，而在 **HaishinKit 底層**。

---

## 根本原因

### 1. HaishinKit 內部大量使用 `Task { }`

HaishinKit 全庫共 **98 個 `Task { }`**（無 `Task.detached`），集中在：

| 檔案 | `Task { }` 數量 |
|------|----------------|
| `RTMPStream.swift` | 16 |
| `MediaMixer.swift` | 16 |
| `RTMPConnection.swift` | 9 |
| `RTMPSocket.swift` | 5 |
| `RTMPSharedObject.swift` | 1 |

全部都是 `Task { }`（非 `Task.detached`），會**繼承呼叫端的 executor context**。

### 2. broadcastStarted 呼叫鏈進入 cooperative executor

```
MainActor Task (broadcastStarted)
  → await configureVideo_init()
    → HaishinKit async method call
      → Swift runtime 切換 executor（從 MainActor → cooperative pool）
        → HaishinKit 內部 Task { }
          → 繼承 cooperative executor（544KB stack）
            → 多個 Task 同時在同一 cooperative thread 上執行
              → actor hop、continuation、遞迴...
                → Stack Overflow 💥
```

**關鍵機制**：當 MainActor task 呼叫非 `@MainActor` 的 async method 時，Swift runtime 會 hop 到 global concurrent executor。在 iOS 27 beta 上，`userInitiated` QoS 的 work 被分配到 cooperative pool（`com.apple.root.user-initiated-qos.cooperative`），而 cooperative thread 的 stack 僅 544KB。

HaishinKit 沒有標記 `@MainActor`，所以所有 HaishinKit async method 都會從 MainActor hop 到 cooperative executor。HaishinKit 內部的 `Task { }` 又繼承了這個 executor。

### 3. 為什麼 `Task.detached(priority: .userInitiated)` 也無效？

`Task.detached` 雖然脫離了 inheriting context，但 **QoS class 沒變**。iOS 27 beta 的 cooperative pool 是對應 `userInitiated` QoS class 的，所以 `Task.detached(priority: .userInitiated)` 仍然被分配到 cooperative thread pool。

這解釋了前面四次修正都無效的原因：改的是 ReplyKIT 自己的 code，但 crash 的根源是 HaishinKit 內部的 `Task { }`。

---

## 技術說明

### Cooperative Queue vs Global Concurrent Executor

| Executor | QoS | Stack 大小 | 用途 |
|----------|-----|-----------|------|
| `com.apple.root.user-initiated-qos.cooperative` | `.userInitiated` | **544KB** | 輕量、短暫的 cooperative task |
| `com.apple.root.default-qos` | `.default` | ~1MB | 一般 async task |
| `com.apple.root.utility-qos` | `.utility` | ~1MB | 背景工作 |
| `MainActor` | N/A | ~1MB+ | UI thread |

### `Task { }` vs `Task.detached`

| | `Task { }` | `Task.detached(priority:) { }` |
|---|---|---|
| Executor 繼承 | ✅ 繼承呼叫端 | ❌ 不繼承 |
| **QoS class** | 繼承 | 可指定（但仍對應到該 QoS 的 pool） |
| Actor context | 繼承 | 無 |
| `@Sendable` 要求 | 無 | ✅ closure 必須 `@Sendable` |

### QoS Class 與 Thread Pool 對應關係（iOS 27 Beta）

```
Task(priority: .userInitiated)     → cooperative pool (544KB stack) ← 問題所在！
Task(priority: .utility)           → utility pool        (~1MB stack) ← 解法
Task(priority: .default)           → default pool        (~1MB stack)
Task(priority: .background)        → background pool     (~1MB stack)
```

---

## 修復策略

### ReplyKIT 層（我方程式碼）

| 檔案 | 修改 | 原因 |
|------|------|------|
| `VideoProcess.swift` | `Task { }` → `Task.detached(priority: .utility)` | 每幀 GPU 旋轉脫離 cooperative |
| `VideoProcess.swift` | FrameGate 移除，改用 `ProcessorActor.isProcessing` guard | 避免 DispatchSemaphore 阻塞 thread |
| `AudioProcess.swift` | `enqueue()` 內 `Task { }` → `Task.detached(priority: .utility)` | 音訊處理脫離 cooperative |

### HaishinKit 層（底層修正）

| 檔案 | 修改內容 | `Task { }` 數量 |
|------|----------|----------------|
| `RTMPConnection.swift` | `Task { }` → `Task.detached(priority: .utility) { }` | 9 |
| `RTMPStream.swift` | `Task { }` → `Task.detached(priority: .utility) { }` | 16 |
| `MediaMixer.swift` | `Task { }` → `Task.detached(priority: .utility) { }` | 16 |
| `RTMPSocket.swift` | `Task { }` → `Task.detached(priority: .utility) { }` | 5 |
| `RTMPSharedObject.swift` | `Task { }` → `Task.detached(priority: .utility) { }` | 1 |
| **合計** | | **47** |

### 為什麼用 `.utility` 而非 `.userInitiated`？

```
.userInitiated → cooperative pool (544KB) ← 不能用
.utility       → utility pool    (~1MB)   ← 安全
```

`.utility` 的 thread pool 不屬於 cooperative 體系，stack 不受 544KB 限制。Live streaming 的音視頻處理可以接受 utility QoS 的略微延遲。

---

## 潛在風險與注意事項

### 1. 大規模 `Task { }` 的風險

任何 Swift 專案若在 cooperative executor context 中大量使用 `Task { }`，都會面臨相同風險。iOS 27 的 cooperative pool 對每個 thread 配置 544KB stack，一旦 actor hop 超過 ~5-6 層就會觸發 stack overflow。

**建議**：在 library 內部優先使用 `Task.detached`，明確指定 QoS class，避免依賴呼叫端的 executor context。

### 2. `DispatchSemaphore` 在 Swift Concurrency 中的風險

`DispatchSemaphore.wait()` 會**阻塞呼叫 thread**。在 Swift concurrency 的 cooperative thread pool 中使用會導致：
- Thread 被永久佔用，pool 縮小
- 其他 task 被迫擠到剩餘 thread，stack 壓力增加
- 可能觸發 thread explosion（runtime 不斷建立新 thread）

**建議**：用 actor 的序列化特性或 `AsyncSemaphore`（actor-based semaphore）取代 `DispatchSemaphore`。

### 3. QoS Priority Inversion

`.utility` 的 task 內部若呼叫需要 `.userInitiated` 回應速度的操作（如 UI 更新），會被系統自動提升 priority。Swift runtime 有內建的 priority escalation 機制，所以不會造成明顯的 priority inversion。

### 4. `Task.detached` 的 `@Sendable` 限制

`Task.detached` 要求 closure 為 `@Sendable`，在 Swift 6 語言模式下會強制所有 captured reference 必須是 `Sendable` 或使用 explicit `self.`。對於 `@unchecked Sendable` 的型別（如 `SampleHandler`），可以編譯通過但需注意執行緒安全。

---

## 與其他 Stack Overflow 問題的對照

| 類型 | 原因 | 觸發時機 | 解法 |
|------|------|----------|------|
| NWConnection 遞迴 | callback 內同步呼叫 `receive()` | Socket 大量資料交換 | 改用 async/await 的 `receive()` |
| 泛型特化遞迴 | `withUnsafeBytes<UInt32>` 編譯器特化 | ByteArray 讀取 | 避免泛型特化，用 concrete type |
| 協程幀遞迴 | `__swift_coroFrameAllocStub` + Metal async | GPU pipeline 初次建立 | Actor 序列化 + `isProcessing` guard |
| **Cooperative Queue** | **HaishinKit `Task { }` 繼承 cooperative executor** | **推流啟動階段** | **`Task { }` → `Task.detached(priority: .utility)`** |

---

## 受影響檔案總表

### ReplyKIT

| 檔案 | 修改 |
|------|------|
| `ReplyKIT/VideoProcess.swift` | `Task { }` → `Task.detached(priority: .utility)`；FrameGate 移除，改用 `isProcessing` guard |
| `ReplyKIT/AudioProcess.swift` | `enqueue()` 內 `Task { }` → `Task.detached(priority: .utility)` |

### HaishinKitFixSwfit (F:\HaishinKit.swift)

| 檔案 | 修改 |
|------|------|
| `RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift` | 9 處 `Task { }` → `Task.detached(priority: .utility)` |
| `RTMPHaishinKit/Sources/RTMP/RTMPStream.swift` | 16 處 `Task { }` → `Task.detached(priority: .utility)` |
| `HaishinKit/Sources/Mixer/MediaMixer.swift` | 16 處 `Task { }` → `Task.detached(priority: .utility)` |
| `RTMPHaishinKit/Sources/RTMP/RTMPSocket.swift` | 5 處 `Task { }` → `Task.detached(priority: .utility)` |
| `RTMPHaishinKit/Sources/RTMP/RTMPSharedObject.swift` | 1 處 `Task { }` → `Task.detached(priority: .utility)` |
