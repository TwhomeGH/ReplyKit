# ScreenCaptureKit 回呼入口診斷

`[CaptureCallbacks] schema=1` 與 CaptureSource 使用同一 session。擷取期間約每五秒回報，收尾排空後另記 stage=finished。

- callbacks：全部回呼，包含被忽略的樣本；video／audio／mic／unknown 分開。
- outcomes：invalid、notReady、missingStatus、nonComplete、missingImage、unknownType 為略過原因；offered 是嘗試交付 mailbox，不代表 mailbox 接受或成功推流。
- states：可解析的畫面狀態 complete／idle／blank／suspended／started／stopped／unknown；不依此推定遊戲或系統故障。
- idleSeconds：距最後回呼時間；沒有回呼為 unknown。maxCallbackGapSeconds 為 session 累計最大間隔，不是這五秒區間的最大值。
- lastPTS、regress、invalidPTS：來源時間與異常計數，包含未交付 mailbox 的樣本。
- hostMinusPTSSeconds：回呼入口 host clock 減樣本 PTS；min／max 為累計極值。時基尚未驗證，不能直接稱為擷取延遲；負值保留，無效 PTS 顯示 unknown。

## 判讀

callbacks 不增加而 idleSeconds 增加，表示 App 沒觀察到新回呼；不能區分系統未交付與回呼佇列未獲排程。callbacks 增加但 offered 少，查 outcomes／states。offered 多但 mailbox 接受少，查 CaptureSource 丟棄計數。Mixer／編碼輸入少則繼續對照後續佇列與旋轉錯誤。

資料只描述回呼與來源時間，不能單獨證明畫面內容新鮮、GPU 正確或伺服器成功解碼。尚需實機對照 10/25 類似活動頁面、靜止畫面與前後景切換。
