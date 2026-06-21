# UInt32 時間戳溢位（2026 年問題）

## 問題

`RTMPHandshake.c2packet()` 將 `Date().timeIntervalSince1970 * 1000` 轉為 `UInt32`：

```swift
// RTMPHaishinKit/Sources/RTMP/RTMPHandshake.swift:60
var ct = UInt32(Date().timeIntervalSince1970 * 1000).bigEndian
```

### 計算

| 項目 | 數值 |
|------|------|
| `timeIntervalSince1970` (2026 年 6 月) | ≈ 1,782,000,000 秒 |
| × 1000（轉毫秒） | ≈ 1,782,000,000,000 ms |
| `UInt32.max` | 4,294,967,295 |
| **溢位倍數** | **×415** |

### Crash 特徵

- **例外：** `EXC_BREAKPOINT / SIGTRAP` (`brk 1`)
- **錯誤執行緒：** `com.apple.root.user-initiated-qos.cooperative`
- **錯誤函式：** `RTMPHandshake.c2packet()` defer block
- **底層 runtime：** `completeTaskWithClosure`（在 async task 中呼叫）
- **發生時機：** RTMP 連線握手階段（C2 packet 發送前）
- **觸發條件：** 系統時間 ≥ 2026 年 4 月（`UInt32.max / 1000 / 86400 / 365 ≈ 56.2 年`）

### 為什麼之前沒發生

RTMP handshake 的 `UInt32` 毫秒時間戳從 1970 年開始計算，在 **2026 年 4 月**左右超過 `UInt32.max`。在此之前 `Date().timeIntervalSince1970 * 1000` 可以容納在 `UInt32` 內。此專案在 2025 年開發時沒有問題，但到了 2026 年 6 月正式觸發。

### 與其他崩潰的關係

這個崩潰和 `VideoProcess` 的 `Task { }` 遞迴沒有直接關係，但兩者都經過 `completeTaskWithClosure`：

| 崩潰 | 原因 | `completeTaskWithClosure` 角色 |
|------|------|-------------------------------|
| Stack Overflow × 7 | `__swift_coroFrameAllocStub` 遞迴 | 執行 task completion 時觸發遞迴 |
| **UInt32 溢位** | **`UInt32(1.78e12)` 溢位 trap** | **在 async RTMP 連線 task 中被呼叫** |

---

## 修復方式

### 原本

```swift
var ct = UInt32(Date().timeIntervalSince1970 * 1000).bigEndian
// UInt32(1_782_000_000_000) → EXC_BREAKPOINT 💥
```

### 修正後

```swift
var ct = UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 1000)).bigEndian
```

用 `Int64` 先撐住數值（最大可到 9.2 × 10¹⁸ ms ≈ 2.9 億年），再 `truncatingIfNeeded` 截斷為 `UInt32`，符合 RTMP 規範的 32-bit timestamp rollover 行為。

### 同類問題待檢查

`clear()` 方法也有 `Date().timeIntervalSince1970` 但只存為 `TimeInterval` (Double)，沒有 overflow 問題：

```swift
timestamp = Date().timeIntervalSince1970  // ✅ Double = 無溢位
```

但 `timestamp` 在 `c0c1packet` 中也有類似模式：

```swift
let c1Timestamp = UInt32(timestamp).bigEndian  // ？？？
```

`timestamp` 是 `TimeInterval`（從 `Date().timeIntervalSince1970` 來的），直接轉 `UInt32` 也會溢位。不過 `c0c1packet` 是 computed property，只在建立連線時呼叫一次，且 crash 尚未在此處被回報。

如果要一併預防，可改為：

```swift
let c1Timestamp = UInt32(truncatingIfNeeded: Int64(timestamp)).bigEndian
```

---

## 受影響檔案

| 檔案 | 修改內容 |
|------|----------|
| `RTMPHaishinKit/Sources/RTMP/RTMPHandshake.swift` (Fork) | `UInt32(Date()...)` → `UInt32(truncatingIfNeeded: Int64(Date()...))` |
| `F:/HaishinKit.swift/RTMPHaishinKit/Sources/RTMP/RTMPHandshake.swift` (Original) | 同上 |
