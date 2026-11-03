# 主 App 外部日誌通道

日誌頁選「外部／全部」後可選 HTTP Web（預設）或已連線 Socket；日誌設定亦提供同一選項。此選項不變更擴展本身的設定、檔案保存與交接。HTTP 是既有 POST 傳送，並非新增 HTTP 接收服務。

## Socket 訂閱

外部工具在既有連線送出一行 JSON：

```json
{"type":"subscribeExternalLogs","enabled":true}
```

回應 `externalLogSubscription` 的 enabled 表示訂閱是否成立；false 可取消，斷線後需重訂閱。未知連線預設不接收。發送擴展專用 logbatch／videoHealth／audioHealth／reconnectStatus 的連線會被標記為擴展並取消訂閱。這是協定角色識別，不是身份驗證；不要向不可信網路公開服務。

一般輸出範例：

```json
{"type":"externalLogBatch","source":"mainapp","id":"UUID","entries":[{"title":"liveApp","body":"訊息","time":"時間"}]}
```

source 表示轉送者，來源由各筆 title 區分。主 App 及收到的擴展 logbatch 可對外轉送，收到回送的 externalLogBatch 直接忽略。舊 log 訊息仍落本地，Socket 通道不再轉送它，避免外部工具回送迴圈。

沒有訂閱者不累積離線日誌，不自動改走 HTTP。沿用每秒最多 150 筆的主 App 外部批次；單批超過 256 KiB 略過，每個接收者排隊達 32 筆或 512 KiB 時略過新批次。介面顯示因慢連線略過的接收者批次次數，不代表對端已處理數。既有非日誌控制訊息不在本次容量政策內。

切換時清除待送緩衝、停止定時器，後續新日誌才重新啟動；已開始的 HTTP 請求／Socket 傳送可能完成，不撤回已發送資料。一般日誌可能含敏感內容，此即時通道不使用診斷檔匯出的遮蔽器。

## 帶外 diagnostic

保留既有 log I/O 失敗的每 60 秒有界摘要，不落盤。接收者改為已訂閱外部工具，排除原連線與擴展；不受一般日誌通道選擇限制。舊工具需新增訂閱才能繼續收到這類診斷。未知 type 應忽略，勿斷線或回送。

## 驗收

待 Apple CI／實機：HTTP 預設相容性、訂閱／取消／重連、擴展排除、logbatch 本地保存、回送忽略、慢工具上限及切換不重播。語法檢查不等於上述行為驗證通過。
