# dSYM 崩潰追蹤工具

## 快速使用

```bash
# macOS — dSYM 目錄，atos 精確到行號
./crash_trace.sh crash.ips -s ./dSYMs

# macOS — 單一 dSYM
./crash_trace.sh crash.ips -s ReplyKIT.appex.dSYM

# Windows — 文字符號表，函數名粒度
python crash_trace.py crash.ips -s symbols.txt

# 純 offset 模式（無符號表）
python crash_trace.py crash.ips

# JSON 輸出
python crash_trace.py crash.ips --json
```

## 三種模式

| 模式 | 平台 | 輸入 | 輸出粒度 |
|------|------|------|----------|
| `atos (行號)` | macOS | dSYM 目錄 | `func (File.swift:行號)` |
| `symbols` | Win/Mac | symbols.txt | `ClassName.methodName` |
| `offsets only` | 通用 | 無 | `+0xc8890` |

## macOS atos 模式輸出範例

```
bug_type 309 (Stack Overflow)  |  thread #6  |  mode: atos (行號)

--- Crash Thread #6 (com.apple.root.default-qos.cooperative) ---
  #      offset  function
  1    +0xc8890  RTMPConnection.supportedProtocols.getter (RTMPConnection.swift:32) (x6) [!] RECUR
  2    +0xc8890  RTMPConnection.supportedProtocols.getter (RTMPConnection.swift:32) (x6) [!] RECUR
  8    +0xbd618  AMF3Serializer.deserialize() (AMF3Serializer.swift:78) +0xdc
 10    +0xcc0fc  RTMPConnection.performConnect(…) (RTMPConnection.swift:425) +0xe8

>>> 遞迴檢測 <<<
  根因: static let lazy 初始化遞迴
  修法: 把 static let 改成 computed var
```

## Windows symbols 模式輸出範例

```
bug_type 309 (Stack Overflow)  |  mode: symbols

--- Crash Thread #6 ---
  #      offset  function
  1    +0xc8890  RTMPConnection.supportedProtocols (x6) [!] RECUR
  8    +0xbd618  AMF3Serializer.deserialize +0xdc
 10    +0xcc0fc  RTMPConnection.performConnect +0xe8

>>> 遞迴檢測 <<<
  根因: static let lazy 初始化遞迴
  修法: 把 static let 改成 computed var
```

## 符號表來源

### macOS（atos 模式，精確到行）
從 Xcode Archive 取 dSYM：
```bash
# Archive 位置
~/Library/Developer/Xcode/Archives/<date>/<app>.xcarchive/dSYMs/

# 使用整個目錄（自動找對應的 dSYM）
./crash_trace.sh crash.ips -s ~/path/to/dSYMs/
```

### Windows（函數名模式）
從 dSYM 匯出文字符號表：
```bash
# 在 macOS 上執行一次
nm -n ReplyKIT.appex.dSYM/Contents/Resources/DWARF/ReplyKIT > symbols.txt
# 或
dwarfdump --debug-info ReplyKIT.appex.dSYM > symbols.txt

# 然後把 symbols.txt 搬到 Windows
python crash_trace.py crash.ips -s symbols.txt
```

## 輸出解讀

1. **第一行** — bug_type、queue、mode：確定 crash 類型和解析精度
2. **Stack Guard + 544K** — cooperative thread 棧溢出
3. **`(xN) [!] RECUR`** — 同一函數重複 N 次，遞迴或 async resume 堆疊
4. **最下面** — 工具自動判斷的根因 + 建議修法

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
