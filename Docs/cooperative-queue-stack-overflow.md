# Cooperative Queue Stack Overflow (bug_type 309)

## 最終解法

**把重度 HaishinKit 呼叫拆成獨立的 `Task.detached(priority: .background)`，每個拿自己的 stack 配額。**

```swift
// ❌ 全部擠在同一 Task → 單一 cooperative stack 累積
Task(priority: .utility) {
    await mixer.startRunning()   // HaishinKit 內部 16+ Task { }
    await startRTMP()            // HaishinKit 內部 25+ Task { }
}

// ✅ 各自獨立 Task.detached → 各自 stack 預算
let mixer = mediaMixer
await Task.detached(priority: .background) {
    await mixer.startRunning()
}.value

await Task.detached(priority: .background) { [self] in
    await startRTMP(url: url, key: key)
}.value
```

---

## 根因

iOS 27 beta 的 Swift concurrency runtime 對多個 QoS 等級引入了 **cooperative thread pool**，stack 僅 544KB：

| Queue 名稱 | Stack | 出現於 |
|-----------|-------|--------|
| `com.apple.root.user-initiated-qos.cooperative` | 544KB | 原始程式碼、`.userInitiated` |
| `com.apple.root.utility-qos.cooperative` | 544KB | `Task(priority: .utility)` |

`Task(priority:)` 改 QoS 無效 — iOS 27 把 cooperative 機制作為 **QoS 層級的行為**，只要 QoS 對應的 pool 有 cooperative 變體就會被分配進去。

`DispatchQueue.global().async { Task { } }` 也無效 — Swift runtime 會偵測 Task 建立的 QoS context 而非 thread 來源。

`.background` 是目前唯一未觀察到 cooperative 變體的 QoS。

---

## Crash 時間線（2026-06-24，全部 bug_type 309）

| 時間 | slice_uuid | 嘗試 | Queue |
|------|-----------|------|-------|
| 15:58 | `eb6a822b` | 原始程式碼 | `user-initiated-qos.cooperative` |
| 16:32 | `43e0a1af` | Video/Audio → `Task.detached(.userInitiated)` | `user-initiated-qos.cooperative` |
| 17:35 | `8c874ad2` | 移除 FrameGate，`isProcessing` guard | `user-initiated-qos.cooperative` |
| 18:04 | `0db57c02` | `.userInitiated` → `.utility`（Video/Audio） | `user-initiated-qos.cooperative` |
| 19:26 | `d491a4ca` | `broadcastStarted` → `Task(priority: .utility)` | **`utility-qos.cooperative`** ← QoS 生效了但還是 cooperative |
| 21:44 | `03ee61a4` | `DispatchQueue.global().async { Task { } }` | `utility-qos.cooperative` ← 換線程系統無效 |
| **最終** | — | **`Task.detached(priority: .background)` 隔離每個重度呼叫** | 待驗證 |

---

## 技術細節

### 為什麼改 QoS 無效？

iOS 27 beta 把 cooperative pool 對應到**特定 QoS 等級**，而非 executor 類型。任何 `userInitiated` 或 `utility` QoS 的工作都會被排進對應的 cooperative pool。

### 為什麼 `DispatchQueue.global().async` 也無效？

Swift runtime 在建立 `Task` 時檢查的是**當前的 QoS context**（由 thread 的 voucher 決定），而非 thread 的來源系統。GCD thread 被 Swift runtime 賦予了對應的 QoS voucher → `Task { }` 繼承這個 voucher → 被排進 cooperative pool。

### 為什麼 `Task.detached(priority: .background)` 可能有效？

`.background` 是唯一從未出現在 crash log 中的 QoS。iOS 27 beta 的 cooperative pool 可能只涵蓋 `userInitiated` 和 `utility` 兩個等級。

即使 `.background` 也有 cooperative 變體，`Task.detached` + `.value` 的組合仍然有效：每個 detached task 是獨立的 top-level task，拿到**自己的** 544KB stack 配額，不會跟 parent task 的 stack 疊加。

### Task.yield() 的作用

`Task.yield()` 暫停當前 task，讓 executor 執行其他排隊中的工作，然後恢復當前 task。它**不保證 stack 重置** — task 恢復時可能回到同一個 thread、同一個 stack pointer。對於 cooperative stack overflow 的情境，`Task.yield()` 不足以解決問題，因為：

- Yield 後 resumption 可能發生在同一個 cooperative thread 上
- Stack 上的呼叫鏈不會被清除，只是暫停
- 真正需要的是**不同的 Task 實例**，各自擁有獨立的 stack 配額

### `Task.detached` + `.value` vs `Task.yield()`

| | `Task.yield()` | `Task.detached(...) { }.value` |
|---|---|---|
| Stack 隔離 | ❌ 同一 Task，同一 stack | ✅ 獨立 Task，獨立 stack |
| 執行順序 | 暫停後恢復 | 等待子 Task 完成後繼續 |
| 適用場景 | 讓出 CPU 給其他工作 | 把深層呼叫鏈移到獨立 stack |

---

## 最終修正總表

### ReplyKIT

| 檔案 | 修改 |
|------|------|
| `VideoProcess.swift` | `Task { }` → `Task.detached(priority: .utility)` + `isProcessing` guard |
| `AudioProcess.swift` | `Task { }` → `Task.detached(priority: .utility)` |
| `SampleHandler.swift` | broadcastStarted：`Task(priority: .default)` + 重度呼叫各包 `Task.detached(.background)` |
| `SampleHandler.swift` | rtmpConnection/rtmpStream 從 `init()` 移到 socket config 後建立 |

### CI/CD

| 檔案 | 修改 |
|------|------|
| `.github/workflows/main.yml` | `push: tags`（因 GITHUB_TOKEN 限制）→ `workflow_run`，簡化 Get tag |

### HaishinKit

| 檔案 | 修改 |
|------|------|
| `RTMPConnection.swift` 等 5 個 actor | **未修改**（actor executor 自成體系，不需要 `Task.detached`） |
| `.github/workflows/*.yml` | 全 rename 為 `.disabled`（避免無用 CI） |

---

## 潛在風險

### `Task.detached(priority: .background)` 的效能影響

`.background` 是最低優先級，系統可能在 CPU 繁忙時延遲執行。但 `broadcastStarted` 的設定階段通常不會與其他重度工作競爭，影響有限。關鍵的 per-frame 處理（VideoProcess/AudioProcess）仍使用 `.utility` 以確保即時性。

### `@Sendable` closure 的 self 捕獲

`Task.detached` 強制 `@Sendable` closure。以 `[self]` 捕獲 `@unchecked Sendable` 的 `SampleHandler` 可編譯通過，但需注意：
- `self` 被強引用捕獲，deinit 不會在 task 完成前執行
- 使用 `.value` 等待完成確保生命週期安全
