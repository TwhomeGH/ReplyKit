# 日誌系統改善 (2026-06)

## 概述

修復 LogManager 的多項設計問題，重點在於：
- 消除日誌丟失（data race、reentrancy drop、單封包過大）
- 將重負載移出 barrier queue，提升整體效
- 側載無 App Group 時自動強制走 Socket 轉送
- 檔案 App 可直接讀取日誌

---

## 1. Socket 傳送修復

### `ReplyKIT/Socket.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| `pendingLogs` data race | `sendLog()` 直接操作 `pendingLogs`，與 `flushPendingLogs()` 跨 queue 競爭 | `sendLog()` 改派發到 `SocketClient.queue` (serial queue) |
| 單一封包 100KB+ | `flushLocalLogs` 將整批 buffer 一次 joined 送出 | 新增 `_sendLogPayload()`，超過 8KB 按 `\n` 邊界分塊 |
| `sendLog` 繞過序列佇列 | 直接呼叫 `sendPayload()`，與其他控制訊息交錯 | 統一經由 `SocketClient.queue` 序列化 |

### `liveAPP/liveAPPApp.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| `receiveSocketLog` 丟失訊息 | 全域 `isProcessingSocketLog` Boolean 做 reentrancy guard，重入直接丟棄 | 移除 guard（Socket Server receive loop 已是 per-connection serial） |

---

## 2. LogManager 效能修復

### `ReplyKIT/Event.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| barrier queue 被阻塞 | `flushLocalLogs()` 在 `logQueue.async(flags:.barrier)` 內做 `.joined()` + JSON 序列化 | buffer swap 留在 barrier（僅 array reference swap），`.joined()` + `sendLog` 移至 `DispatchQueue.global(qos:.utility)` |
| 三倍記憶體 | buffer array + joined String + JSON Data 同時存在 | 分割為 swap → (off barrier) joined → send |

---

## 3. 檔案 App 日誌存取

### `liveAPP/Info.plist`

加入兩個 key，使主 App 的 `Documents/` 目錄出現在 iOS 檔案 App：

```xml
<key>UIFileSharingEnabled</key>
<true/>
<key>LSSupportsOpeningDocumentsInPlace</key>
<true/>
```

### `liveAPP/liveAPPApp.swift` — AppLogPersister

新增 class `AppLogPersister`，使用獨立 serial queue 將 log 寫入 `Documents/log.txt`：

- Socket log → `receiveSocketLog()` 觸發寫入
- App Group log → `LogReceiver.flushBuffer()` 觸發寫入
- 主 App 自身 log → `sendlog()` 觸發寫入
- App 啟動時 → 自動複製 App Group 既有 log 到 Documents/
- 清除日誌 → 一併清空 Documents/log.txt

---

## 3.1 主 App 寫檔改進 — 批次化 + 持久 handle + 就地截斷 (2026-08)

### 背景問題

`AppLogPersister` 原實作對**每一筆 log** 都做一次完整檔案 I/O：

```
sendlog() / receiveSocketLog() / Socket logbatch / [PIP_Chat] 每一條
    → append(line:/lines:) → queue.async { write(data) }
    → fileExists 檢查 → FileHandle(forWritingTo:) 開啟 → seekToEndOfFile
    → write → closeFile
```

| 寫入來源 | 觸發 | 頻率 |
|----------|------|------|
| `sendlog()` (liveAPPApp.swift:658) | 主 App 自身事件（心跳、頁面切換、RTMP 狀態、BGTask） | 低〜中 |
| `[PIP_Chat]` (PIPContent.swift:1897) | **每一條聊天訊息** | 高（聊天多時每秒數筆） |
| E-Socket `log`/`logbatch` (Socket.swift:1039-1052) | extension 每 ~250ms~1s flush 一次 | 中 |
| `LogReceiver` (SocketLog 停用時) | Darwin 通知觸發讀取，throttle 1-3s | 中 |

問題在於「每筆 append = 一次 open/seek/write/close」——`[PIP_Chat]` 每條聊天都觸發一次完整的 syscall 序列，高頻時是不必要的 I/O 開銷；且 `trimNow()` 超 7000 行時**讀取整個檔案 + split + 原子重寫**（O(n)）。

### 修正（`liveAPP/liveAPPApp.swift`）

| 層面 | 改前 | 改後 |
|------|------|------|
| **寫入粒度** | 每筆 log 一次 FileHandle open/seek/write/close | 記憶體 `pendingLines` 累積，滿 **50 筆** 或 **0.5 秒**（先到先 flush）一次整批寫入 |
| **handle 生命週期** | 每次 append 開檔再關 | 首次寫入時 `openWriteHandle()` 開啟並保存 `writeHandle`，後續重複使用，`clear()` 才 truncate |
| **trim** | 讀整檔 + `atomically` 原子重寫 | `truncate(atOffset:0)` + `seek(toOffset:0)` 就地覆寫後截斷，省一次整檔寫入 |
| **背景落盤** | 無（被 kill 遺失 pending） | 新增 `flushNow()`，`.background` 場景呼叫，進入背景前強制落盤 |

### 行為差異

| 情境 | 改前 | 改後 |
|------|------|------|
| 正常日誌量（每秒 <50 筆） | 每筆一次檔案寫入 | 每 0.5 秒一批（約 1-2 次/s 檔案寫入） |
| 高頻聊天（每秒 >50 筆） | 每筆一次，頻繁 open/close | 每 50 筆一批 flush |
| UI 即時顯示 | 依賴 `LogBuffer`（0.05s debounce） | **不變**——`LogBuffer` 與 `AppLogPersister` 獨立，UI 仍即時 |
| 檔案 App 讀取 | 每次寫入後即見 | 最遲 0.5 秒後見（批次延遲），`flushNow()` 可立即落盤 |
| 強制關閉 (force quit) | pending 都在記憶體，可能全丟 | 仍可能丟最後 ≤0.5s 批次（iOS 不保證 `willTerminate`），但有 `early-log.txt` 兜底 |
| trim 觸發 | 全檔原子重寫 | 就地截斷，I/O 減半 |

### 保留 API

`append(line:)`、`append(lines:)`、`copyFromAppGroup()`、`clear()`、`totalWrittenBytes` 全部不變，呼叫方（`sendlog`、`receiveSocketLog`、Socket `logbatch`、`LogReceiver`、ContentView、OtherView）無需改動。

---

## 4. 側載自動偵測

無 App Group 環境下（sideload），日誌系統自動切換為全 Socket 模式。

### 偵測方式

兩側各自獨立偵測，不依賴 Socket 傳遞狀態：

```swift
var isSideload: Bool {
    FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.nuclear.liveAPP"
    ) == nil
}
```

### Extension 端 (`ReplyKIT/Event.swift`, `ReplyKIT/Socket.swift`)

| 行為 | 說明 |
|------|------|
| `RPConfig.init()` | 側載下強制 `enableSocketLog = true` |
| `writeLogToFile()` | 側載下 `guard return`，不寫入看不見的 extension 私目錄 |
| `setupFlushTimer()` | 側載下 bypass `onLogPage` 閘門，永遠 flush |
| `logConfig` 回調 | 收到主 App 的 `enableSocketLog` 後再蓋回 `true` |

### 主 App 端 (`liveAPP/liveConfig.swift`, `liveAPP/Setting.swift`)

| 行為 | 說明 |
|------|------|
| `LPConfig.init()` | 側載下強制 `SocketLog = true` |
| 設定頁 UI | 側載：顯示 🔒 鎖頭 +「側載模式：Socket 日誌強制啟用」，Toggle 隱藏 |
| | 非側載：完全維持原有行為，用戶自由開關 |

### 流程

```
有 App Group:
  Extension ──┤ enableSocketLog 可開關
               ├── onLogPage 控制是否 flush
               └── 可選 file / socket / both

無 App Group (側載):
  Extension ──┤ enableSocketLog = true (強制)
               ├── onLogPage 不影響 flush
               ├── writeLogToFile() → skip
               └── 所有 log 走 socket

  主 App  ──┤ SocketLog = true (強制)
             ├── Setting UI 隱藏 toggle
             └── AppLogPersister 寫入 Documents/log.txt → 檔案 App 可見
```

---

## 受影響檔案

| 檔案 | 異動摘要 |
|------|----------|
| `ReplyKIT/Event.swift` | isSideload, flushLocalLogs async, setupFlushTimer bypass, writeLogToFile guard |
| `ReplyKIT/Socket.swift` | sendLog queue dispatch, 8KB chunking, logConfig sideload override |
| `liveAPP/Info.plist` | UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace |
| `liveAPP/liveAPPApp.swift` | AppLogPersister, receiveSocketLog remove reentrancy guard |
| `liveAPP/ContentView.swift` | 清除日誌聯動 AppLogPersister |
| `liveAPP/liveConfig.swift` | LPConfig.isSideload + init 強制 SocketLog |
| `liveAPP/Setting.swift` | 側載 UI 唯讀提示 |
