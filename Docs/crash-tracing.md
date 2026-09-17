# dSYM 崩潰追蹤工具

`crash_trace.py` 讀 Apple `.ips` crash report，把符號化、死因判定與跨執行緒死鎖分析一次做完。
**最重要的特性：它會驗證符號來源與這份 crash 是否相符，不再張冠李戴。**

## 快速使用

```bash
# 建議：指向含 dSYM 的目錄（用 crash 的 slice_uuid 挑正確的那份）
python crash_trace.py crash.ips -s "path/to/xcarchive/dSYMs"

# 單一 dSYM
python crash_trace.py crash.ips -s path/to/liveAPP.app.dSYM

# 舊式 nm 符號表（會檢查模組名，不符就拒絕符號化）
python crash_trace.py crash.ips -s symbols_text.txt

# 純 offset 模式（無符號來源）
python crash_trace.py crash.ips

# JSON 摘要
python crash_trace.py crash.ips -s <dSYMs> --json
```

macOS / Linux 也可用 wrapper：`./crash_trace.sh crash.ips -s <dSYMs>`

## 四種模式

| 模式 | 條件 | 輸出粒度 |
|------|------|----------|
| `dSYM(UUID ✓)` | 提供 dSYM，且 `LC_UUID == crash.slice_uuid` | `funcName +0x…`（跨平台原生解析 nlist） |
| `atos(UUID ✓)` | 同上且在 macOS 且有 `atos` | `funcName (File.swift:行號)` |
| `symbols` | 提供 `.txt`，且模組名相符 | `ClassName.methodName` |
| `offsets` | 無來源或來源不符 | `imageName`（**絕不猜**） |

## 符號來源驗證（本工具最重要的修正）

**問題**：iOS 主 App 與 appex 的 Mach-O preferred base 都是 `0x100000000`。若拿 appex 的符號表去解主 App 的 address，舊工具會用「最近符號」硬湊，產生**看似合理但完全錯誤**的函數名。

**真實案例**：把 `ReplyKIT.appex` 的 `symbols_text.txt` 拿去解 `liveAPP` 的 crash，frame 16 的 `liveAPP+0x4bbbc` 被標成
`SampleHandler.updateLogPageState +0xb8` —— 實際上那格是 liveAPP 的 `_main`（距離 `0xb8` 只是巧合），整個 stack 根本沒有任何 ReplyKit 函數。

**現在的行為**：

- `-s <目錄>`：解析每個 dSYM 的 `LC_UUID`，**只採用與 crash `slice_uuid` 相符**、且檔名等於 image 0 名稱的那份。
- `-s <*.txt>`：檢查符號是否含 image 0 模組的 Swift 前綴（例如 `7liveAPP`）；找不到就拒絕使用並印 `⚠️` 警告。
- 兩者都不符 → `offsets` 模式，只顯示 image 名，**絕不做假符號化**。

> 因此：`E:\Video5\crash-symbols*\` 裡的 `symbols_text.txt` 是 **ReplyKIT appex 的**符號表；
> 要解 liveAPP 的 crash，請改用同層的 `liveApp.xcarchive\dSYMs`（並確認 UUID 相符）。

## 死因判定（termination）

`bug_type` 只描述訊號種類，**不代表死因**。工具改讀 `termination`：

| termination | 標示 | 意義 |
|-------------|------|------|
| `0x8BADF00D` | Watchdog Deadlock | 主執行緒卡住（死鎖），被 scene-update watchdog 砍掉 |
| `0xDEAD10CC` | Watchdog File Lock | 持有檔案鎖被砍 |
| `0xC00010FF` | CPU Limit | 背景超時 |
| `0xBAADCAFE` | Bad Memory Access | 記憶體錯誤 |
| `vmRegionInfo` 含 `Stack Guard` | stack overflow | 執行緒棧溢出 |

例：`bug_type 309` 舊版一律標成 "Stack Overflow"，但同一份報告的 termination 其實是
`0x8BADF00D … is stuck (deadlock)` —— 兩者是完全不同的病。

## 跨執行緒死鎖分析

當主執行緒卡在 lock（`__psynch_mutexwait` / `__ulock_wait` / `semaphore_wait`）時，工具會掃描其他執行緒，
找出「在 SwiftUI/AttributeGraph 更新中、又同步等 main queue（`_dispatch_sync_f_slow`）」的持有者，
並印出該執行緒的 App 端堆疊（最內層通常就是觸發者）：

```
--- 死鎖分析 ---
偵測到跨執行緒死鎖：
  持有 SwiftUI/AttributeGraph lock 的 thread #7 (com.apple.uikit.datasource.diffing)
    在 graph update 中同步等 main queue：__DISPATCH_WAIT_FOR_QUEUE__
    App 端堆疊（outer → inner，最內層通常就是觸發者）：
      - liveAPP.LiveVolumeModel.updateVolumes(mic: Float?, app: Float?, persist: Bool) -> ()
      - liveAPP.SocketServer.handleDecodedPayload(data: Data, type: String, connection: NWConnection) -> ()
      - closure #1 … in liveAPP.SocketServer.handleReceivedData(_: Data, from: NWConnection) -> ()
  → main 等 movable lock、該 thread 等 main，互等即死鎖；watchdog 隨後砍掉 App。
```

Swift 符號會優先用 `swift-demangle` 還原（未安裝才退回內建啟發式）。

## 遞迴 / async resume 堆疊偵測

除了死鎖，工具仍會標記同一函數在 stack 上重複出現的狀況：

```
  #      offset  function
  1    +0xc8890  RTMPConnection.supportedProtocols.getter (RTMPConnection.swift:32) (x6) [!] RECUR
  8    +0xbd618  AMF3Serializer.deserialize() (AMF3Serializer.swift:78) +0xdc
  10   +0xcc0fc  RTMPConnection.performConnect(…) (RTMPConnection.swift:425) +0xe8

>>> 遞迴檢測 <<<
  根因: static let lazy 初始化遞迴
  修法: 把 static let 改成 computed var
```

## 符號表來源

### 直接使用 dSYM（建議，跨平台）
從 Xcode Archive 取：

```bash
# Archive 位置
~/Library/Developer/Xcode/Archives/<date>/<app>.xcarchive/dSYMs/

# 使用整個目錄（自動用 UUID 找對應的 dSYM）
python crash_trace.py crash.ips -s ~/path/to/dSYMs/
```

Windows 也能用：工具原生解析 Mach-O `LC_SYMTAB`，不需要 `atos`/`nm`。
**一定要用 UUID 相符的那份** —— Xcode 每次 Archive 都會換 UUID，舊 dSYM 對不上新 crash。

### 舊式 nm 符號表（備援）

```bash
# 在 macOS 上匯出（注意：要對應正確的 binary —— 主 App 或 appex）
nm -n liveAPP.app.dSYM/Contents/Resources/DWARF/liveAPP > symbols.txt

# 然後在 Windows 使用
python crash_trace.py crash.ips -s symbols.txt
```

工具會檢查符號表裡的模組名是否與 image 0 相符，不符會拒絕使用。

## 輸出解讀

1. **第一行 `[死因]`** — 先看死因，別被 bug_type 誤導
2. **`termination:`** — 系統給的原始終止原因
3. **`⚠️`** — 符號來源驗證失敗等警告
4. **`(xN) [!] RECUR`** — 同一函數重複 N 次，遞迴或 async resume 堆疊
5. **`死鎖分析`** — 跨執行緒死鎖的持有者與 App 端堆疊

## 工具檔案

| 檔案 | 說明 |
|------|------|
| `crash_trace.py` | 主工具 (Python 3) |
| `crash_trace.sh` | macOS/Linux wrapper |
| `crashlog_analyzer.py` | 日誌/IPS 分析工具（跨平台，支援多種 bug_type） |
| `crash-tracing.md` | 本文件 |

---

## 日誌 / IPS 分析工具 `crashlog_analyzer.py`

跨平台 Python 3 工具，無需 dSYM 即可快速瀏覽 crash report、GPU hang、資源異常、Analytics 及一般 log 的關鍵資訊。

### 支援格式

| 格式 | bug_type | 內容 |
|------|----------|------|
| Apple Crash Report (`.ips`) | 309 | Crash 例外終止、執行緒堆疊、記憶體分布、模組列表 |
| GPU Hang Event (`.ips`) | 284 | GPU Hang、IOFence 阻塞 surface 分析 |
| Resource Exception (`.ips`) | 145 | 磁碟寫入等資源異常、持續時間 |
| Analytics (`.ips.ca.synced.txt`) | 211 | 系統統計事件計數、bundleId 分布 |
| ReplyKit log (`.txt`, `.log`)| - | 時間範圍、事件統計、閒置超時、FPS、背景任務 |

### 用法

```bash
# 單一檔案（自動判斷格式）
python crashlog_analyzer.py crash.ips
python crashlog_analyzer.py crash.ips.ca.synced.txt
python crashlog_analyzer.py log.txt

# 掃描整個目錄
python crashlog_analyzer.py E:\Video5\crash-symbols
```

### 輸出範例

**Crash Report (bug_type 309):**
```
[DEV] Device: iPad13,18
[ID] Bundle: nuclear.liveAPP.ReplyKIT
[APP] App: ReplyKIT (v2.3)
[X] Exception: EXC_BAD_ACCESS (Segmentation fault: 11)
[THR] Thread 2 queue=com.liveapp.logQueue  << FAULT THREAD
    _swift_release_dealloc+48
    RefCounts::doDecrementSlow<PerformDeinit>+240
[MEM] Malloc 41.3M  |  IOAccelerator 1152K
```

**GPU Hang (bug_type 284):**
```
[GPU] GPU Analysis
  Restart Reason: blocked by IOFence
  Signature: 627
  IOFence blocked surfaces: 2
    Surface 104: 2 active, 0 waiting
    Surface 18: 1 active, 2 waiting
```

**Resource Exception (bug_type 145):**
```
[DUR] duration: 19m 37s (1177534.0 ms)
```

**ReplyKit Log:**
```
[TIME] Time: 2026-07-13 11:44:03
[STAT] VFrame: 57840
[STAT] PIP: 24
[NET] Idle Timeouts: 8
[FPS] PIP FPS: min=4.0 max=24.0 avg=10.2
[TASK] BGTask scheduled: 1  |  Skipped (PiP active): 3
```
