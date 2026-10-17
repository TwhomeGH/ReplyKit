# RTMP 時間軸診斷接入

套件版本：`d7ece58808efc052e8b1d444888d3a3255b55b1f`。兩份 Package.resolved 須一致，實機以 BuildInfo 確認產物實際使用的 checkout。

## 取得方式

- ScreenCaptureKit：主 App 的 CaptureTransport 白名單放行 `publish timeline`，沿用 session 標記與敏感資訊遮蔽。底層約每 10 次 status 產生一筆，不額外新增計時器。
- ReplayKit：開始推流前啟用 RTMP 日誌，底層 debug 事件經既有 `[RTMP]` 路徑轉送；一般日誌儲存／轉送設定也須啟用。
- 同時保留 `publish throughput`、`audio resync:` 與影音補償事件以對照。正常停止或短於取樣間隔的串流不保證有最後一筆摘要。

## 判讀

`sourceStart`／`sourceLast` 是編碼後、RTMP 補償前的來源時間；`effective` 為重標後時間；`generated` 是產生的 RTMP delta 累計，不能當作網路成功送出或伺服器確認。

`sourceMinusGenerated` 持續變大時，檢查 `gapsOver2s`、`clamps`、`regress`、`corrections` 與 `retime`。`generatedAVOffset` 須搭配影音各自 sourceStart，不能直接解讀為口型偏移。

本次只接入日誌；底層尚未公開對應的結構化快照，因此不解析日誌字串來填設備資訊。混音前後逐軌診斷與停止排空順序仍屬後續項目。

## 驗收

- BuildInfo 確認套件 revision，開始推流並等待至少 20 秒，搜尋 `publish timeline`。
- ScreenCaptureKit 應帶 CaptureTransport 與 session；ReplayKit 開啟 RTMP 日誌後應帶 RTMP 前綴。
- 比對同場 SRS 原始 FLV 與 Oryx 轉碼日誌；保留內容不同步開始的位置與方向。
- 主 App／擴展完整建置與實機日誌須由 Xcode／CI 驗證。
