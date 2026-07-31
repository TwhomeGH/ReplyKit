# 移除 MemoryWarning 監聽設計

## 2026.07.31

## 背景

App 原本監聽 `UIApplication.didReceiveMemoryWarningNotification`，收到系統記憶體壓力警告時：

1. **PIPService**：清空 `pixelBufferPool` + `cachedFormatDescription`（強制 PiP 渲染管線重建）
2. **SocketServer**：清空所有 receive/send buffer（包括在途 log payload）

## 問題

此設計對推流穩定性有害：

| 影響 | 說明 |
|------|------|
| **PiP buffer pool 中途重建** | 推流中清掉 pixelBufferPool，Metal 渲染管線需重新配置，造成畫面跳動/卡頓 |
| **Socket buffer 全清** | `releaseMemory()` 把 sendQueues / pendingFailedPayloads 全部 `removeAll()`，在途的 log 直接遺失，且可能與正在進行的 socket I/O 競爭 |
| **推流中斷** | 兩者合併造成整個 AV 管線不穩，嚴重時推流中斷 |

## 變更

| 檔案 | 移除內容 |
|------|---------|
| `liveAPP/liveAPPApp.swift` | `didReceiveMemoryWarningNotification` 監聽 block |
| `liveAPP/PIPService.swift` | `handleMemoryWarning()`（清 buffer pool + cached format） |
| `liveAPP/Socket.swift` | `releaseMemory()`（清空 socket buffers） |

## 變更後行為

收到 memory warning 時 app 不再介入。記憶體壓力交由系統自行處理（必要時系統會終止 app，而非在推流中破壞管線狀態）。
