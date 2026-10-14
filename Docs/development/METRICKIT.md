# MetricKit 本機效能報告

## 使用方式

設備資訊 → 系統效能報告 → MetricKit 歷史報告。可以查看收到時間、報告涵蓋期間、內容分類與原始 JSON，也可以分享單份報告。

主 App 啟動時由 `MetricReports.shared.start()` 訂閱一次，視窗建立與銷毀不重複註冊。使用相容舊 iOS 的 MXMetricManagerSubscriber API；新版 SDK 可能提示此 API 已被新版 MetricManager 取代。

## 資料與限制

- 效能報告通常涵蓋前 24 小時，系統依來源最多每日提供一次；診斷報告另行交付。不是即時採樣，也不能保證每次異常都有報告。
- 僅接主 App，不能把此處報告當作 ReplayKit 擴展監控。
- `Documents/MetricReports` 保存 JSON，內容包含 schemaVersion、kind、receivedAt、buildInfoAtReceipt 與原始 report。
- buildInfoAtReceipt 是接收報告時的產物資料；事件版本仍應依原始 report 的 metadata 判斷，避免跨更新歸因錯誤。
- 依原始 JSON 的 SHA256 去重，最多保留最近 30 份、總量 20 MB；每份上限 5 MB。較舊或超限的檔案會自動移除。保存失敗會顯示錯誤。
- 不自動上傳。重新整理只讀取已保存報告，不能要求系統立即提供新報告。
- 長期保存摘要，詳細 JSON 開啟時才讀取；檔案 I/O 在專用串行 queue 執行。

## 程式入口

- `MetricReports`：訂閱、去重、保存、保留上限與列表更新。
- `MetricReportsView`：報告列表與 JSON 查看／分享。
- `liveAPPApp.init`：App 生命週期註冊入口。

## 驗收

須在 Xcode／實機驗證收到 MetricKit 報告、多視窗不重複訂閱、JSON 分享、重啟載入及保留上限。Windows 語法檢查不等於 Apple SDK 型別檢查。

參考：[MetricKit](https://developer.apple.com/documentation/metrickit)、[MXMetricManager](https://developer.apple.com/documentation/metrickit/mxmetricmanager)。
