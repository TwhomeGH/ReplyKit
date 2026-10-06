# log-49 管線停滯與記憶體調查

## 已確認的證據

- 2026-10-07 02:24:59，ScreenCaptureKit session E92A12FA 的 RTMP 連線遭遠端重設，隨後進入重連。
- 02:25:12 至 02:36:07，混音輸出探針 delivered 固定 4257；mixed 從 4408 增加到 35100。這不是只有 UI 沒刷新，至少 Mixer 產出與輸出端接收不再一致。
- 02:36:08 開始停止，02:36:09 capture.stopEnd 之後沒有 cleanupComplete；前一個 session 有完成清理。需要新階段日誌定位卡住的 await。
- 日誌 LiveActivity 記憶體最高 346.8 MB；使用者另觀察到約 500 MB、壓縮 398.3 MB，尚無同時間的檔案證據。
- log-49 未含 BuildInfo；目前 App checkout 鎖定 f04e19e2358f279d8b735c3b7f8672b65131f8ad，不能直接當作 log-49 的產物版本。

## 程式核對

- VideoHealthModel / AudioHealthModel 由 Socket videoHealth / audioHealth 更新，屬 ReplayKit 擴展資料；歷史上限 120 筆，未接 ScreenCaptureKit。
- AppLogPersister.shared 使用序列佇列寫入 Documents/log.txt；多視窗不等於多個檔案寫入器。CaptureCoordinator 也是單例，但每視窗的 View 與生命週期工作仍可能重複。
- 上述鎖定版本 AudioCaptureUnit.output 使用預設無界 AsyncStream，並 clone PCM 後 yield；消費停止時存在累積風險。尚未以 Allocations 確認實際保留物件。
- 鎖定版本 MediaMixer.stopRunning 缺少 videoIO.finish；目前底層 HEAD 已加入。App 尚未更新鎖定版本，本次不混入全部底層更新。

## 本次改動

- Info.plist 明確關閉多視窗支援；需在 Xcode 產物確認 UIApplicationSceneManifest.UIApplicationSupportsMultipleScenes=false，並實機測試新視窗入口。
- ReplayKit Pipeline 顯示資料來源與更新年齡，超過 15 秒標示過期。既有數值明確標為最後回報。
- ScreenCaptureKit 顯示獨立本機摘要，每五秒更新來源佇列與混音探針，不宣稱 RTMP 已送出。
- CaptureResources 每約三十秒記錄主程序 footprint/compressed/resident/available；收尾 pump、RTMP stream、Mixer、connection 的 await 前後各記錄一次。
- 裝置頁重複出現時先取消既有取樣計時器。

## 待驗證與下一步

1. 同版產物測試斷線重連、停止、再次開始，確認 delivered 恢復且 cleanupComplete 出現。
2. 比對記憶體增長與 delivered 停滯時間；用 Instruments Allocations/Memory Graph 確認 PCM、Task、Mixer 是否被保留。compressed 已包含於 footprint，不能再相加。
3. 底層評估音訊佇列位元組／時間預算、丟棄與消費停滯統計，以及輸出 consumer 的取消與重建。限制容量不能取代定位 consumer 為何停止。
4. 評估更新 App 套件鎖定版本，先審查版本差異並跑 CI；不能假定目前 HEAD 已修好此次停滯。
5. 手動恢復應叫「重新連接擴展診斷」，只處理本機 Socket。需獨立控制通道、request ID／回覆、逾時、節流與舊連線世代隔離；無擴展或通道不可用需明確提示，不重啟 RTMP／擷取，不以送出請求當作成功。此按鈕尚未實作。

Windows 僅做 Swift 語法解析及靜態檢查；iOS 編譯、記憶體及多視窗驗收待 CI／實機。
