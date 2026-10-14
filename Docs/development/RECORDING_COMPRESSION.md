# ScreenCaptureKit 本地錄影：錄後壓縮

## 使用入口

主頁 → 擷取與開始 → ScreenCaptureKit → 本地錄影設定 →「錄後壓縮（SDR）」。預設關閉，設定在下次開錄時固定，與 RTMP 推流設定分開。

系統錄製編碼與錄後壓縮編碼是兩個階段。HEVC 是有損壓縮編碼，不是 MP4 容器；選用 HEVC 本身不保證檔案比 H.264 小。

| 選項 | 預設 | 用途 |
| --- | --- | --- |
| 完成錄影後壓縮 | 關閉 | 系統完成檔案後，才進行處理 |
| 壓縮編碼 | HEVC | 可選 H.264，提高播放相容性 |
| 目標平均碼率 | 8 Mbps | 可選 1–40 Mbps；不是硬性大小上限 |
| 最長邊上限 | 1920 px | 可選保留、1280、1920、2560；不放大，輸出偶數尺寸 |
| FPS 上限 | 60 | 可選保留、30、60；以原始時間戳限制接受頻率 |

8 Mbps 的視訊約為每分鐘 60 MB，另加音訊與容器。實際大小取決於內容與編碼器。降低碼率、尺寸或 FPS 都可能降低畫質或流暢度。

## 處理與失敗行為

- 使用 `AVAssetReader` 解碼，再以 `AVAssetWriter` 寫入 MP4。僅支援單一 SDR 視訊軌，AAC 音軌直接複製，不調整音訊碼率。
- 固定方向透過軌道矩陣處理；多段方向使用 video composition，與壓縮合併一次轉碼。多段方向可能依 composition 的固定幀率取樣。
- 先產生暫存檔，檢查時長、影音軌數、檔案大小；只有成功且比原檔小才替換。
- 不支援的格式、讀寫失敗、取消或背景時間到期，都保留原始錄影並顯示原因。該次方向修正也可能尚未套用。
- 請保持 App 在前景。背景執行時間由系統決定，不能保證長影片能在背景完成。
- 錄後處理需要額外磁碟空間、耗電與讀寫；**不會減少 SCRecordingOutput 初次錄製時的碼率或 I/O**。空間預檢只是估算，仍可能遇到寫入失敗。
- 本次入口只處理新錄影；既有錄影的手動重試與批次壓縮尚未加入。

## API 與排查入口

- `RecordingCompressionSettings`：開錄時的設定快照；`outputSize` 計算尺寸，`estimatedVideoMBPerMinute` 回傳視訊大小估算。
- `RecordingFrameRateLimiter.accepts(seconds:)`：回傳是否接受該時間戳，不重寫時間戳。
- `RecordingTranscoder.compress`：成功回傳結果文字；失敗拋出錯誤。輸出不比原檔小也視為未套用。
- `RecordingOrientationCorrector.correct`：統一方向與壓縮的收尾入口。
- `[RecordingPostprocess]` 日誌記錄設定、耗時、結果或錯誤 domain／code／description。

主要 AVFoundation 參數：`AVVideoCodecKey`、`AVVideoWidthKey`、`AVVideoHeightKey`、`AVVideoCompressionPropertiesKey` 中的 `AVVideoAverageBitRateKey`（bps）與 `AVVideoMaxKeyFrameIntervalDurationKey`（秒）。FPS 由接受影格的時間戳控制，不依賴碼率設定。

## 驗證

已新增單元測試涵蓋設定驗證、預設關閉、不放大、直向縮放與幀率限制。Windows 已編譯執行抽取自正式程式的尺寸與 FPS 邏輯驗證，完整 liveAPPTests 仍需 Apple SDK。Apple SDK 建置與實機編解碼驗收集中追蹤於 [TODO](../../TODO.md)。

## 容量顯示與寫入方式

系統錄製期間持續寫入同一個 MP4，並非整段影片先堆在 RAM；停止並收到系統完成回呼後，才讀取原檔進行轉碼。可控分段錄製則使用另一條直接編碼路徑，見下方。轉碼期間原檔與暫存輸出同時存在，因此峰值磁碟需求約為兩者總和，另加系統暫存。

主頁與本地錄影共用容量資料：壓縮前大小固定保存；轉碼輸出每秒取樣並標示「未完成」；成功後才顯示壓縮後大小、節省 MB 與百分比。容量使用十進位 MB。舊紀錄沒有壓縮前資料時只顯示檔案大小，不回推。

8 Mbps 是目標平均碼率，約 1 MB／秒，不代表每秒固定寫 1 MB。56 秒、54.6 MB 的整檔平均約 7.8 Mbps（包含音訊與封裝）。平均碼率模式採最長關鍵幀間隔 2 秒，其餘參數沿用編碼器預設。另提供系統高品質預設與多次編碼請求；沒有提供 CRF／固定量化品質或恆定碼率選項。

`SCRecordingOutputConfiguration` 沒有公開碼率參數。初次錄製碼率由新加入的可控分段錄製（AVAssetWriter）設定控制；系統錄製的錄後壓縮設定仍只在停止後生效。分段錄製則是另一項檔案生命週期設計，不會單靠分段降低碼率。

ScreenCaptureKit 的 Mixer 每 200 ms 合併讀取 appVolume／micVolume，有變化才套用。推流與可控分段錄製共用此混音輸出；本地系統錄影仍使用 SCRecordingOutput 混音，不套用這兩個音量設定。

## 可控分段錄製（測試中）

- 開啟「可控分段錄製」後，直接以 AVAssetWriter 編碼 MP4，不再建立 SCRecordingOutput 或執行錄後壓縮。
- 可選 HEVC／H.264、1–40 Mbps 或編碼器自動碼率、保留尺寸／最長邊 1280／1920／2560，以及不額外限制／30／60 FPS。
- 自動碼率表示省略 AVVideoAverageBitRateKey；仍會重新編碼，不能視為無損或原始壓縮資料直通。
- 預設每 120 秒一段，可選 60／120／300／600 秒。以視訊時間戳觸及邊界切換 writer；每段獨立編碼與完成，檔案與群組／序號分開持久化，不自動合併。
- 已完成片段不受後續片段失敗影響；片段內設定 10 秒 movieFragmentInterval 增加中斷可恢復機會，不保證突然斷電的最後資料完整。
- 重新啟動後，中斷項目可按「驗證並恢復可播放部分」。只有檔案能載入有效視訊與時長才允許恢復；不能推定事故前全部內容都已保存。
- 沿用 Mixer 畫布、左轉與疊加層；系統錄影的方向政策不套用。音訊混成單一 AAC 48 kHz／雙聲道／128 kbps 音軌，獨立 appVolume／micVolume 先在 Mixer 生效。
- 佇列上限 48 MiB，正常運作時清除超過 2 秒的積壓；停止時排空已接受樣本。Writer 暫時忙碌與佇列過載會丟樣本並記錄，切段收尾可能造成短暫缺口；尚未承諾逐樣本無縫切段。
- 系統錄製仍保留且為預設。兩種錄製模式在下一次啟動時生效。

## 系統高品質與多次編碼

錄後壓縮可選「系統高品質預設」。使用 H.264／HEVC 對應的 ExportSession 預設，輸出大小與品質由系統決定，此時不傳入手動 Mbps、尺寸或 FPS。

「允許系統嘗試多次編碼」設定 canPerformMultiplePassesOverSourceMediaData，由匯出器管理重新讀取，不保證特定設備或編碼器一定使用多次編碼。這不是 CRF 固定品質，也不保證更小；仍要通過時長／軌數及檔案較小的驗證才替換原檔。即時錄製不使用多次編碼。
