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
| `crash-tracing.md` | 本文件 |
