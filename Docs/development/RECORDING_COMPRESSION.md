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
