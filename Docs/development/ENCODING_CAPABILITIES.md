# 編碼選項與健康指標入口

## H.264 裝置能力

主頁 → 編碼設定，展開後查詢 VideoToolbox ProfileLevel 支援清單。清單是該尺寸與模式的編碼器回報值，不保證所有 FPS、碼率、像素格式组合均可用。沒有清單時保留原值並顯示未確認；不補入猜測選項。

- `H264EncodingProfile.resolve`：共用設定解析。舊 Baseline／Main／High 改為同 Profile 的 AutoLevel；舊 Auto 與 Constrained／Extended 名稱仍相容；系統完整 H264 值原樣保留。未知舊值沿用 Main AutoLevel 後備。讀取不寫回偏好。
- `H264EncoderCapabilities.query`：依尺寸／低延遲模式建立短期 session，讀取支援字典，結果包含 values、status、stage。失敗不快取，最多保存八組成功結果；查完 invalidate，不編碼測試影像。
- `EncodingSettingsView`：獨立卡片，保存到原 `h264level` 鍵，沿用 Socket 配置同步。未指定輸出尺寸時使用 1920×1080 參考尺寸並提示。
- ReplayKit 使用保存的低延遲條件；ScreenCaptureKit 推流目前固定一般 H.264，但共用 Profile 解析。本地 SCRecordingOutput 不受此設定控制。
- Baseline 使用 CAVLC。移除固定 60 FPS 的自製 Level 推算；真正 session 建立與設定仍由底層驗證，查詢結果不是實際編碼輸出。
- 展開卡片才查詢，取消後不套用結果。查詢持有短期 CaptureLease；有 App Group 可排除擴展擷取，側載本地鎖不能保證跨程序互斥。查詢鎖不可用時可稍後手動重試。

HEVC 清單仍是既有設定，尚未做能力列舉。不要把它標為裝置已確認支援。

## 健康指標契約

| 指標 | 定義與實作狀態 |
| --- | --- |
| mixerAudioSampleRate | 已接入共用 StreamDiagnosticsSnapshot；從 Mixer PCM format 取得 Hz，鎖內取樣／複製，兩種來源共用。未收到音訊為 nil，設備資訊頁顯示未提供。 |
| audioHealth.sampleRate | 保留舊提案欄位，傳送端未提供。新實作使用上列明確階段欄位，不用回呼 FPS 換算。 |
| latencyAvg／Max／P95 | 現有 GPU 完成耗時，單位毫秒，不代表端到端或網路延遲。 |
| timeoutDelta | 現有彙總視窗 Metal 逾時次數增量，不是百分比。 |
| latencyExceedCount | 已定義但未採集：視窗內 GPU 完成耗時超標的幀數；必須同時提供 latencyThresholdMs、latencySampleCount、latencyWindowSeconds。缺值維持 nil。 |
| totalLatencyMs | 保留但未採集，不當作端到端延遲。來源 PTS 與本機時鐘不能直接相減。 |

新增可選欄位保持舊訊息解碼相容。健康模型在主佇列保存 latestPayload，保留 nil；不將未知指標加入既有數值圖表。liveConfig 是配置／畫面狀態入口，不另放一份診斷資料。

## 後續量測設計

GPU 超標計數應由完成回呼所在的序列化狀態統一更新，以單調時鐘計時；每個視窗輸出超標數、總量測數、閾值與視窗秒數。切換 session 或閾值時清空視窗，避免混合統計。須先確認底層可取得逐幀完成耗時，再接入傳送端；不能由 avg／P95 反推幀數。

音訊先分別量測排隊、重採樣、混音處理耗時，使用同一單調時鐘和對應樣本識別。不同音軌可並行，不直接相加；真正端到端量測需要接收端協作。實作前保持 totalLatencyMs 為 nil。

## 驗證

新增舊設定遷移、能力清單不補值、非法尺寸、舊健康訊息解碼及取樣率 round-trip 測試。Windows 僅能執行 Swift 語法解析；Apple SDK 型別檢查、VideoToolbox 查詢及實機開播仍待 CI／裝置驗收。完整待辦集中於 TODO.md。
