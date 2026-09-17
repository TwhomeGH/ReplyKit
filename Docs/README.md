# 文件索引

本目錄收錄開發／除錯／設計文件。主專案說明請見上層 [README.md](../README.md)。

- 新增**修復紀錄** → 執行 `python Scripts/change_log.py`（或雙擊 `Scripts/change_log.cmd`）開本機網頁 GUI，或直接寫進 [ChangeHistory.md](ChangeHistory.md)
- 新增**主題文件** → 在下面對應分類加一行連結

## 變更與開發紀錄

| 文件 | 說明 |
|------|------|
| [ChangeHistory.md](ChangeHistory.md) | 完整變更歷史（新→舊）；所有修復／新增／優化條目 |
| [github-alerts.md](github-alerts.md) | GitHub alert（`> [!WARNING]` 等）語法與渲染支援說明 |
| [design-issues.md](design-issues.md) | 設計問題紀錄（含執行緒／主執行緒等通則） |
| [replykit-core-fixes-summary.md](replykit-core-fixes-summary.md) | ReplyKit 核心修正與性能改進總覽 |

## 崩潰診斷 / 偵錯

| 文件 | 說明 |
|------|------|
| [crash-tracing.md](crash-tracing.md) | dSYM 崩潰追蹤工具（`crash_trace.py` / `crashlog_analyzer.py` 用法、UUID 驗證、死鎖分析） |
| [cooperative-queue-stack-overflow.md](cooperative-queue-stack-overflow.md) | AsyncStream yield() 同步鏈造成 cooperative thread stack overflow |
| [coroutine-frame-recursion.md](coroutine-frame-recursion.md) | Swift 協程幀分配器無窮遞迴 |
| [generic-specialization-recursion.md](generic-specialization-recursion.md) | 泛型特化遞迴（ExpressibleByIntegerLiteral） |
| [nw-recursion.md](nw-recursion.md) | NWConnection 遞迴 receive 模式 |
| [page-switch-crash-analysis.md](page-switch-crash-analysis.md) | 頁面切換崩潰：HaishinKit Buffer Overflow 損毀 Swift String |
| [uint32-overflow-2026.md](uint32-overflow-2026.md) | UInt32 時間戳溢位（2026 年問題） |

## 串流 / 媒體管線

| 文件 | 說明 |
|------|------|
| [av-pipeline.md](av-pipeline.md) | 影音管線架構 |
| [haishinkit-fixes.md](haishinkit-fixes.md) | HaishinKit 修正記錄 |
| [metal-shader-optimizations.md](metal-shader-optimizations.md) | Metal Shader 性能優化 |
| [video-dimensions.md](video-dimensions.md) | 影片尺寸設計：AD / OD |
| [video-output-pool-lifetime.md](video-output-pool-lifetime.md) | GPU 輸出 Pool 與使用期限 |
| [bitrate_mode.md](bitrate_mode.md) | 位元率模式說明 |

## Socket / 日誌 / 記憶體

| 文件 | 說明 |
|------|------|
| [socket-wire-protocol.md](socket-wire-protocol.md) | E-Socket Wire Protocol |
| [log-system-improvements.md](log-system-improvements.md) | 日誌系統改善（2026-06） |
| [replykit-log-socket-stability.md](replykit-log-socket-stability.md) | ReplyKIT 日誌與 Socket 穩定性改進 |
| [memory-warning-removal.md](memory-warning-removal.md) | 移除 MemoryWarning 監聽設計 |

## PiP / UI / 畫面

| 文件 | 說明 |
|------|------|
| [pip-performance-improvements.md](pip-performance-improvements.md) | PiP 性能優化（2026-07） |
| [pip-layout-config.md](pip-layout-config.md) | PIP 排版加工設計 |
| [overlay-scene-config.md](overlay-scene-config.md) | 畫面加工 Overlay 配置設計 |
| [audio-volume-page.md](audio-volume-page.md) | 音量控制頁說明 |
| [localization.md](localization.md) | 本地化與翻譯流程 |

## 流程 / 版本 / 其他

| 文件 | 說明 |
|------|------|
| [workflow.md](workflow.md) | 本地建置工作流程 |
| [version.md](version.md) | 版本標記說明 |
| [sponsor.md](sponsor.md) | 贊助支持說明 |
| [apple-feedback-template.md](apple-feedback-template.md) | Apple Feedback Assistant 回報模板 |

## 工具

| 檔案 | 說明 |
|------|------|
| [`crash_trace.py`](crash_trace.py) / [`crash_trace.sh`](crash_trace.sh) | `.ips` 崩潰符號化、死因判定、跨執行緒死鎖分析 |
| [`crashlog_analyzer.py`](crashlog_analyzer.py) | 跨平台日誌／IPS 快速瀏覽工具 |
| [`../Scripts/change_log.py`](../Scripts/change_log.py) / [`../Scripts/change_log.cmd`](../Scripts/change_log.cmd) | 變更歷史工具：本機網頁 GUI（新增／搜尋／就地編輯／刪除、深淺色切換、GitHub alert 樣式預覽）＋ CLI 子命令 |
