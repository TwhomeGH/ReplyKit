# ScreenCaptureKit 雙來源接入

## 使用方式

在開播頁的「螢幕擷取方式」選擇 ReplayKit 或 ScreenCaptureKit。預設維持 ReplayKit；新來源標為測試中。停止直播後才能更換來源。

ScreenCaptureKit 路徑會呈現系統分享選擇器，取得使用者選擇後，依工作模式啟動推流、錄製或兩者。主 App 的「停止擷取」會關閉擷取、樣本消費端、Mixer 與 RTMP，再釋放跨程序直播鎖。取消選擇不會改用 ReplayKit。直播中更改系統分享選項會停止，請重新開始以套用新選擇。

## 快速操作

1. 在開播頁選擇「ScreenCaptureKit（測試中）」；選項不可用時，先確認系統及 App 版本符合下列 SDK 條件。
2. 選擇工作模式。只錄製可保留空白 RTMP 設定；只推流或推流並錄製須填入有效網址與串流金鑰。
3. 按下對應的開始按鈕，在系統選擇器確認分享內容與麥克風選項。
4. 觀察擷取狀態、推流狀態及錄製秒數／大小；「擷取中」不等於推流已成功，推流成功另顯示「推流中」。
5. 按「停止擷取」，等待收尾完成。到「本地錄影」播放、分享／匯出，或存入照片。

### 操作異常時

| 情況 | 行為與處理 |
| --- | --- |
| 另一個來源正在使用擷取 | 無法取得跨程序擷取鎖；先停止既有工作，再啟動 |
| 使用者取消系統選擇器 | 結束此次啟動，不會自動改用 ReplayKit |
| 推流失敗，但錄製仍有效 | 顯示推流錯誤並繼續錄製；目前不提供工作中手動重啟推流 |
| 錄製失敗，但推流仍有效 | 顯示錄製錯誤並繼續推流；原檔保留在錄影目錄 |
| 錄影顯示未確認完成 | 未收到完成回呼；不開放播放或匯出，可保留或刪除紀錄 |
| 拒絕新增照片權限 | App 內原檔保留，可改用分享／匯出 |

## SDK 與系統條件

- Deployment Target 維持 iOS 16.6。
- ScreenCaptureKit 需要 Xcode 27 SDK 與 iOS 27 實機。程式同時檢查編譯旗標、模組可匯入、系統版本與分享選擇器可用性。
- 主 App 的 iPhoneOS／iPhoneSimulator 27.x SDK 自動加入 `SCREEN_CAPTURE_KIT_IOS27`。舊 SDK 不編譯新 API，只保留 ReplayKit；未來更新 SDK 主版本時須同步新增 SDK 條件，不能在舊 SDK 強制開啟旗標。
- 新框架在 SDK 27 的建置中使用弱連結，搭配執行期版本判斷保留舊 iOS 啟動能力。
- Mac Catalyst 此次不接入新路徑。
- Info.plist 新增 `screen-capture` 背景模式與螢幕擷取用途說明，保留 `audio` 背景模式及麥克風用途說明。
- 新來源使用主 App，沒有搬移或移除 Broadcast Upload Extension。

## 目前功能範圍

| 項目 | ScreenCaptureKit 測試版 |
| --- | --- |
| 全螢幕與背景擷取 | 系統選擇器、SCStream |
| 音訊 | 系統聲音 track 0、使用者選擇的麥克風 track 1 |
| 畫面 | 使用輸出畫布尺寸，未設定時 1920×1080；尺寸取偶數並限制在 3840×2160 範圍內 |
| 擷取頻率 | 請求最多 60 FPS，不代表系統會持續交付 60 FPS |
| 編碼 | H.264 High、無 B-frame、AAC；畫面維持比例 |
| 推流設定 | 開始時讀取 RTMP 網址／金鑰、碼率、碼率模式、關鍵幀間隔及雙軌音量 |
| 網路 | 底層自適應碼率與重連；重連耗盡停止推流，仍有效的本地錄製繼續 |
| 本地錄製 | SCRecordingOutput、MP4／H.264，可只錄製或邊推流邊錄製 |
| 診斷 | VideoQueue 與 CaptureSource，每五秒記錄 |
| 自訂 GPU 畫布、旋轉、浮水印 | 尚未接入，使用 ReplayKit |
| 降噪、AGC、既有音訊處理器 | 尚未接入，使用 ReplayKit |
| 設定即時更新、HEVC | 此測試路徑尚未接入；設定在下次開播生效，編碼固定 H.264 |

這一版共用 Mixer 的建立與基本音訊配置，尚未把大型 SampleHandler 的所有影音前處理抽出。新來源不會假裝已套用 ReplayKit 專用 GPU 或音訊處理設定。選單已提示差異，切回 ReplayKit 可繼續使用既有完整功能。

## 程式結構

- `SharedCapture/CaptureMediaPipeline.swift`：兩個 target 共用的 Mixer 與雙軌配置。
- `SharedCapture/CaptureLease.swift`：App Group 檔案鎖，跨程序阻止兩個來源同時執行；程序退出後由 OS 釋放。
- `SharedCapture/CaptureMailbox.swift`：單一消費端、依位元組與停留時間限制的樣本佇列。
- `liveAPP/Capture/CaptureCoordinator.swift`：選項、可用性檢查、直播鎖與使用者狀態。
- `liveAPP/Capture/CaptureSessionState.swift`：工作階段識別與合法狀態轉移。
- `liveAPP/Capture/ScreenCaptureSource.swift`：系統選擇器、SCStream、RTMP 與停止清理。
- `liveAPP/Capture/CaptureAudioOwnership.swift`：擷取期間保護 Audio Session，PiP/TTS 不得覆蓋錄音設定。
- `liveAPP/Capture/ScreenRecordingSession.swift`：系統錄製輸出、進度及完成／失敗回呼。
- `liveAPP/Capture/RecordingLibrary.swift`：持久紀錄、重啟復原、錄影列表與檔案操作。

## 佇列與生命週期

擷取回呼使用獨立序列佇列，只驗證並放入樣本。影像只接受有效、就緒且狀態為 complete 的樣本；idle／blank 等非完整影格不交給編碼器。

影像樣本佇列預算為 12 MiB，系統音訊與麥克風各 1 MiB，停留時間上限 100 ms，慢消費時淘汰舊樣本。SCStream 的 queueDepth 設為 3；這是系統擷取緩衝，與後段樣本佇列分開。這些數字不是程序總記憶體上限，還有系統緩衝、消費端持有樣本、GPU 及編碼器用量。

停止時先標記 stopping、取消啟動、推流與診斷工作，等待啟動中的操作退出；移除錄製輸出並停止 SCStream，等待錄製完成回呼，再關閉樣本佇列與下游。只在清理完成後釋放直播鎖。舊回呼無法把 stopping 工作改回 streaming，關閉的佇列不接受晚到樣本。

PiP/TTS 的音訊配置透過共同保護執行；擷取使用麥克風時保存並暫時修改 Audio Session 分類，停止後還原分類。為避免中斷仍在播放的 PiP/TTS，不直接強制停用整個 App 的 Audio Session。此行為需納入實機音訊測試。

## 診斷欄位

`CaptureSource` 記錄 backend、session、mode、phase，以及 video／audio／mic 各自的 accepted、dropped、queued、bytes／budget。

- accepted：通過基本容量／關閉檢查並送入樣本佇列的數量，不代表編碼完成。
- dropped：超大、逾時、容量淘汰或關閉後送入的數量。
- 非完整或無效 SCStream 影格在進入樣本佇列前被略過，目前不包含在上述計數。
- bytes：目前佇列持有資料，不包含下游與系統擷取緩衝。

底層 `VideoQueue` 提供後段編碼與 RTMP 入列證據；兩者都正常仍不能證明伺服器已成功解碼。來源錯誤只顯示錯誤碼，避免底層錯誤訊息含有串流金鑰。

## 驗證與實機驗收

Windows 可執行狀態機、有界佇列與音訊所有權的核心測試，以及 Swift 語法／plist 格式檢查。這不等於通過 Apple SDK 型別檢查或 iOS 實機驗證。

在 Xcode 27 與 iOS 27 上應驗證：

- 舊 SDK 與 iOS 16.6～26 維持 ReplayKit 可用；新選項不可啟動。
- 系統選擇器取消、拒絕、重複點擊、連線期間停止、系統停止分享。
- 主 App 切到遊戲、回到前景、直橫轉換與長時間背景推流。
- 麥克風開／關、系統音訊靜音、耳機切換、來電／Audio Session 中斷。
- PiP 與 TTS 啟停期間麥克風持續、停止擷取後兩者仍可使用。
- 與系統 ReplayKit 廣播同時啟動時只有一個來源取得鎖，失敗的一方不清理另一方的直播。
- 慢網路、重連與停止重開，確認不殘留 SCStream／RTMP／consumer。
- 用相同遊戲與輸出設定比較 CPU、GPU、記憶體、溫度與延遲，不預設新框架更省資源。

## 官方參考

- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [Capturing screen content on iOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios)
- [SCStream](https://developer.apple.com/documentation/screencapturekit/scstream)

## CI 與集中待辦

`iOS Unit Tests` workflow 在 PR、分支 push 或手動觸發時，使用 `liveAPP` scheme 於可用的 iPhone Simulator 執行 `liveAPPTests`。發布流程也會呼叫同一套測試，測試失敗時不進入建置／發布工作。CI 保存 `.xcresult` 和日誌，便於定位失敗。

測試與發布 CI 使用 `xcode-27` runner，固定 `DEVELOPER_DIR=/Applications/Xcode_27.0.app/Contents/Developer`。兩者都檢查 iPhoneOS 與 iPhoneSimulator SDK 必須是 27.x；環境不符直接失敗。單元測試僅選擇 iOS 27 的 iPhone Simulator，避免舊 runtime 略過新功能。runner 目前為公開預覽，實際編譯與執行結果仍須以 CI 日誌為準。

尚未接入的 GPU、浮水印、音訊處理、即時設定與 HEVC，以及首次 CI／實機驗證，統一追蹤於 [TODO.md](../TODO.md)。

## 本地錄製使用方式

選擇 ScreenCaptureKit 後，可選「只推流」「只錄製」「推流並錄製」。ReplayKit 維持原本的直播流程，不套用此工作模式。

- **只錄製**：不驗證 RTMP 網址／金鑰，也不建立 RTMPConnection、RTMPStream、Mixer 或樣本消費佇列；由 SCRecordingOutput 編碼檔案。
- **推流並錄製**：共用 SCStream，但推流與錄影各有編碼輸出。推流連線失敗或重連耗盡時，仍有效的錄製繼續；錄製失敗時，正在啟動或運作的推流繼續。兩者皆失效時結束擷取。
- 按「停止擷取」會停止所有輸出，畫面維持收尾狀態，直到資源清理完成。
- 「本地錄影」可查看狀態、錄製秒數與檔案大小。完成後可播放、分享／匯出、存入照片或刪除；只有按「存入照片」時才請求新增照片權限。

錄影保存至 App 的 `Application Support/ScreenRecordings/<UUID>.mp4`，旁邊的同名 JSON 保存狀態；不依賴暫存目錄。刪除 App 會連同內部錄影刪除，需要保留的影片請先匯出。App 重啟後，上次未完成的紀錄標記為「未確認完成」，保留原檔，避免把不完整 MP4 當成可播放影片。

### 錄影內容與限制

本地錄影使用 SCStream 的設定：輸出尺寸、最多 60 FPS、系統音訊及使用者選取的麥克風。音訊合併成單一軌道，影片固定 MP4／H.264。錄影不套用 RTMP 的自適應碼率、碼率設定、Mixer 音量、自訂 GPU 浮水印或進階音訊處理；實際檔案碼率由系統錄製器決定。

推流與錄製可能同時使用兩個編碼器，不能直接推論比只推流更省資源。「錄製經過處理的最終推流畫面」尚未實作，已列在根目錄 TODO.md。

### 狀態與完成判定

正常流程為 `preparing → recording → finishing → ready`。`recording` 由系統開始回呼設定，`ready` 只能由系統完成回呼設定，停止擷取的方法返回不代表檔案已完成。

- `failed`：系統錄製失敗或無法掛載錄製輸出。
- `interrupted`：停止後等待完成回呼超過 30 秒、等待被取消，或 App 重啟發現未完成紀錄。
- 終態不接受晚到回呼覆寫；失敗或逾時的檔案不開放播放／匯出，仍可刪除。
- 30 秒是停止擷取返回後的錄製收尾等待上限，不是整個停止流程的時限；RTMP 與系統擷取操作仍依各自 API 返回。
- 狀態轉移寫入 JSON，每秒的錄製時間／大小只更新畫面，避免每秒寫入清單檔。

### 新增內部 API

以下 API 由主 App 管理，尚未提供 Socket 遠端錄製指令。

| API | 返回／通知 | 用途 |
| --- | --- | --- |
| `CaptureWorkMode.accepts(endpoint:key:)` | `Bool` | 只錄製直接接受；需推流時驗證 RTMP／RTMPS 網址與非空金鑰 |
| `CaptureCoordinator.startScreenCapture(url:key:mode:)` | `Void`；透過 published 屬性通知 | 驗證條件、取得擷取鎖並開啟系統選擇器；預設模式為只推流 |
| `CaptureCoordinator.phase` | `CapturePhase` | 擷取生命週期；內部 `streaming` 代表擷取已啟動，不代表 RTMP 已發布 |
| `CaptureCoordinator.isPublishing` | `Bool` | RTMP 已成功發布後為 true；只錄製永遠為 false，亦不啟動直播動態活動 |
| `CaptureCoordinator.errorMessage` | `String?` | 授權、擷取或輸出錯誤；可能只影響其中一個輸出 |
| `CaptureCoordinator.stop()` | `Void` | 排程停止；觀察 phase 回到 idle 才表示清理完成 |
| `RecordingLibrary.recordings` | `[LocalRecording]` | 由新到舊的錄影清單；包含進行中及未完成紀錄 |
| `RecordingLibrary.create()` | `LocalRecording`，可能拋錯 | 建立 UUID 與持久紀錄，尚不代表開始錄製 |
| `RecordingLibrary.fileURL(for:)` | `URL` | 依 UUID 推導 App 管理的 MP4 路徑，不保證檔案已存在或完成 |
| `RecordingLibrary.delete(_:)` | `Void`，可能拋錯 | 只刪除已結束的紀錄及原檔 |
| `RecordingLibrary.saveToPhotos(_:)` | async `Void`，可能拋錯 | 只處理 ready 檔案；要求 addOnly 權限並新增影片 |
| `ScreenRecordingSession.attach(to:)` | `Void`，可能拋錯 | 將系統錄製輸出加入同一個 SCStream |
| `ScreenRecordingSession.detach(from:)` | `Void` | 要求移除輸出，進入收尾；不代表完成 |
| `ScreenRecordingSession.awaitCompletion()` | async `Void` | 等待完成／失敗，或將逾時紀錄標為 interrupted；最終結果在清單中 |

`LocalRecording` 欄位：`id: UUID`、`created: Date`、`phase: RecordingPhase`、`duration: Double`（秒）、`bytes: Int64`（位元組）、`message: String?`。時間與大小來自 SCRecordingOutput 的統計，進行中只作為目前進度；`phase == ready` 才能用於播放與分享。`RecordingLibrary.errorMessage` 另外回報目錄或紀錄儲存失敗。

診斷日誌新增 `[Recording] id=<UUID> phase=<狀態>`；`CaptureSource` 的 `mode` 區分三種模式，只錄製會顯示 `sampleQueues=none`。

### 本次驗證

Windows 執行 12 項擷取核心測試與 3 項錄影檔案管理測試，合計 15 項全部通過，涵蓋工作階段、有界佇列、Audio Session 所有權、錄製模式驗證、收尾／晚到回呼、持久紀錄復原、進行中檔案刪除保護及損壞紀錄隔離。檔案測試直接使用 RecordingLibrary 的持久化方法，在暫存副本中替換 ObservableObject／Published 宣告並排除 Photos／SwiftUI 畫面，實際讀寫獨立測試目錄；不代表 Apple UI 或照片整合已驗證。新增 Swift 檔案移除平台條件後的語法解析與 Info.plist 檢查通過。這些檢查不包含 ScreenCaptureKit、SwiftUI、Photos 的 Apple SDK 型別檢查或真實錄影。

實機應測試：空白 RTMP 的只錄製、拒絕／取消擷取、麥克風開關、背景錄製、開始後立即停止、斷網繼續錄影、磁碟不足但推流繼續、錄製收尾失敗／逾時、App 被終止後重開、播放與分享、照片權限拒絕及儲存、長時間雙編碼的溫度與記憶體。

官方 API：[SCRecordingOutputConfiguration](https://developer.apple.com/documentation/screencapturekit/screcordingoutputconfiguration)、[SCRecordingOutputDelegate](https://developer.apple.com/documentation/screencapturekit/screcordingoutputdelegate)。
