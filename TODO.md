# TODO 待辦事項

集中管理全專案實作進度與驗收事項。

`[x]` 表示該項描述已完成；實作與實機／CI 驗收分開記錄，避免尚待驗收被誤讀為功能尚未開發。最近部分核對：2026-11-06（PiP 分段提示／頭貼／計時列、App 圖示、RTMP 樣本、AltStore、設定備份、SCK 收尾與 CI 選機；其餘舊章節未全面重驗）。工作目錄已完成但尚未提交的實作也可標記完成，並另註驗收限制。

> 新待辦請寫在這裡，不要在各文件的角落另開 TODO 區塊；完成後改為 `[x]`（整批清理時可移除已完成項）。

## 2026-11-06 核對摘要

- 已實作（尚未全部驗收）：PiP 計時器併入狀態列、隱藏控制列精簡版面、次要提示分段與可選頭貼、邊緣遮罩每幀重建修正；設定備份損壞／過大舊檔輪替與前景背景髒標記；PiP 效能摘要改 5 分鐘／異常 1 分鐘；SCK 收尾有上限並記錄 stage；AltStore 來源改由 Release 附件產生；CI 選機改用可用 runtime、SDK 優先與開機 fallback；RTMP 內建 JSON 樣本與個人樣本匯入／匯出；App 圖示明確尺寸、診斷與包體檢查。
- 待驗收：上述的實機 PiP 排版／分段切換／頭貼載入、檔案匯入匯出、SCK 停止（含啟動中取消）、AltStore 首次附件與穩定 URL、CI 圖示宣告與新選機流程、App 圖示實機切換。
- 下一批：推流配置（含串流金鑰）專用匯入；PiP 時間圖層進一步快取；其餘舊章節的 CI／實機驗收。

## 閒置資源量測

- [x] 新增 IdleResources 與生命週期快照，列出擷取、PiP、TTS 的實際狀態或持有資訊。
- [ ] 冷啟動不開播，前景等待 60 秒後進背景，再返回並匯出日誌；對照 app.start／periodic／app.background.afterCleanup／app.foreground 的 footprint 與工作狀態。
  - 2026-11-07 兩筆要分開看：舊 process `A79F…` 在 uptime 1986 的 idle 是 109MB，但日誌從 12:02 才開始，不知道它前 33 分鐘做了什麼，不能當冷啟動。新 process `17505…` 在 12:51:52 冷啟動：footprint **3.9 → 29.7MB**，60 秒內穩定在 29.5～29.8MB；這才是目前可用的 warm idle 基準。`resident` 約 122MB 是 external mapped frameworks，不是 footprint。舊 process 的 109MB 累積原因仍待查。
- [ ] 開播後停止，等待至少 60 秒；確認 capture.finished 的 driver／lease 已釋放，並比較後續 footprint。另測 PiP、TTS 分別開關，避免把有背景工作的狀態當作完全閒置。
  - 2026-11-07 已取得一次正常停止：`capture.finished`、`finish stage=complete elapsedMs=5368`、driver／lease=false；停止後 0／10／19.6／49.7 秒 footprint 約 144.8→141→140.5→142.3MB，`reachedStopSeconds=[30]`。尚未達 60 秒，且 PiP／TTS 沒有單獨開關對照。
- [ ] **停止後殘留追查**：舊 process `A79F…` 的 pre-capture idle 為 109.2MB，停止後 49.7 秒仍 142.3MB（約 +33.1MB；internal 65→104）；PiP pool 僅約 2.75MB，因此差值不在 PiP pool。這個 109MB 本身也不是冷啟動基準；需用新 process 的 ~30MB warm idle 重做短開播停止比較，再定位是聊天／日誌／診斷歷史、SCK／Metal 快取或其他子系統。
- [ ] **舊 process 累積原因**：`A79F…` 在無 capture 狀態下到 109MB，但新冷啟動 `17505…` 只有 ~30MB；需從舊 process 啟動就開始的日誌確認是 UI 狀態、日誌／診斷歷史、圖片快取或先前活動留下，不能只用 12:02 之後的片段判斷。
- [ ] **建議量測順序**：A. 冷啟動不開播，前景等 60～120 秒（背景 60 秒再回前景），匯出這一段，取得 warm idle；B. 短開播約 5 分鐘後停止，等 60／120 秒再匯出；C. 只開 PiP；D. 只跑 TTS。每段用精確時間範圍匯出，不要先用一小時混合視窗；確認 baseline 後再另外做一小時 idle soak。
- [ ] **日誌頁／暫存 A/B**：從 ~30MB warm idle 開日誌頁、搜尋整份檔、匯出診斷、關閉，分別在 30／60 秒量 footprint；若殘留 >5MB 再改。程式目前有上限：LogModel 1000 行（暫存 2000）、LogBuffer 5000、檔案頁 200 行／1MiB、搜尋 500 筆；診斷匯出是 64KiB 分塊寫磁碟。若日誌頁沒有明顯殘留，優先查 PiP／聊天／圖片快取與舊 process 的先前活動。
- [x] App init 寫入 `[AppSession] launch` 標記；診斷匯出新增「本次啟動到現在」，以 `launchDate - 1s` 為起點並顯示啟動時間。
- [ ] **本次啟動匯出驗收**：重新啟動 App、等待再匯出，確認只含本次程序、包含 launch marker、背景返回不改變起點。
- [ ] 對照同期間 JetsamEvent 確認終止原因；每日峰值與接收報告時的版本不能代表終止當下的用量／版本。

## MetricKit

- [x] 主 App 單次訂閱、本機報告保存、設備資訊查看／分享入口及容量限制。
- [x] 報告摘要與詳細頁自動換算容量，詳細頁可切回原始單位；分享 JSON 保留原值。
- [x] **已觀測到系統報告產生**：使用者曾提供 `3fd04f6cfadccbb650dc1625d86630c6f0740faa4a48e84699d6fcdb630eab79.json`，後續確認報告摘要可查看；不再將整個報告接收流程列為未驗收。
- [ ] **JSON 分享驗收**：從一份報告點「分享 JSON」，存到檔案 App；重新開啟確認可解析，且內容與「查看原始 JSON」相同。
- [ ] **重啟載入驗收**：已有報告時關閉並重新啟動 App，確認歷史報告仍出現在列表且可以開啟；無需等待系統再次交付。
- [ ] **保留上限驗收**：以測試資料製造超過 30 份可讀報告或總量超過 20 MB，重新整理後確認優先保留較新的報告且未超限；單份超過 5 MB 不應保存。此項使用測試副本，避免清掉需要保留的真實報告。
- [ ] **重複開啟／單次訂閱驗收**：目前 App 設定單視窗；多次進出報告頁、背景返回後確認列表不重複，同一報告不產生多份檔案。若未來重新開放多視窗，再補跨視窗驗收。
- [ ] **新容量顯示驗收**：用已有報告切換「自動 KB／MB／GB」與「報告原始單位」，確認只改顯示，分享的 JSON 保留原值；換算邏輯已有測試，畫面待實機確認。

API 遷移屬後續技術評估，不作為以上功能完成的條件；需要時另立包含目標 API、支援版本與遷移理由的工作項目。

## 共用設備診斷（2026-10-19）

- [x] ReplayKit／ScreenCaptureKit 共用 Mixer 影片與 PCM 輸出速率卡片，本地可控錄製也回報；歷史有上限。
- [x] 設備頁顯示實體介面上行／下行差分，註明包含其他 App 流量。
- [x] **ScreenCaptureKit 混合輸出圖表實機驗收**：使用者提供 2026-10-20 15:50 設備頁截圖，Video／Audio Pipeline 均顯示 ScreenCaptureKit、歷史曲線與輸出速率；兩張截圖的更新時間與影片 FPS 有變化，本機來源佇列及混音摘要亦可見。
- [ ] **其餘管線圖表驗收**：ReplayKit 圖表、停止與重啟、本地可控錄製、回前景與介面切換；截圖中的 ReplayKit 尚未收到資料，不作為該來源驗收。
- [x] 底層公開編碼後格式快照：從實際壓縮樣本更新影片 codec／寬高／色彩、音訊 codec／取樣率／聲道／封包資訊，定義 session／generation 與重連重設語意。
- [x] App／ReplayKit 接入上述快照，替換「實際編碼輸出格式」的缺口說明；不以設定或文字日誌冒充實測。
- [x] 底層 7ce4304b 前置工作已由使用者於 2026-10-20 確認完成；主 App 兩份鎖定檔均接入該版本。
- [x] **ScreenCaptureKit 實際編碼與缺值顯示實機驗收**：2026-10-20 15:50 截圖顯示影片 `avc1.64002A`、1920×1080；音訊 AAC、48000 Hz、2 聲道、1024 sample frames/packet。格式變更時間、最近影音壓縮輸出時間、樣本／packet 與 payload 累計均已顯示。編碼色彩附件缺值維持「未提供」，Mixer BGRA 顯示 RGB／matrix 不適用。
- [ ] **其餘編碼診斷驗收**：ReplayKit 實際格式、長時間連續輸出時間更新、重連清空與世代切換；本次截圖不替代完整 CI 結果。
- [ ] 來源佇列、丟幀及耗時的完整健康快照統一；本批共同圖表僅涵蓋 Mixer 輸出，ReplayKit 進階健康資料仍分開呈現。

## ScreenCaptureKit 後續管線

- [x] 推流與可控錄製共用 Mixer，即時套用 appVolume／micVolume；RTMP 清理與擷取管線分離。
- [x] 停止收尾的 diagnostics／operation／publishing／stopCapture／錄製完成與管線停止都有上限，逾時仍回 idle；每一步記錄 `finish stage=... elapsedMs=...`。
- [ ] **SCK 停止實機驗收**：啟動中取消、串流中停止、錄製收尾、背景切換與重複停止，確認不會停在「正在停止擷取」，並用 stage 日誌定位慢步驟。
  - 2026-11-07 已驗證一次正常停止：`finish stage=complete elapsedMs=5368`、driver／lease 釋放、deinit；啟動中取消、錄製收尾與重複停止仍待。
- [x] 可控分段錄製：AVAssetWriter 直接編碼、可指定／自動碼率、獨立片段索引及中斷檔案驗證入口。
- [x] 錄後系統高品質預設與多次編碼請求；與手動平均碼率模式分開。
- [x] **分段錄製曾實機產出**：使用者提供 `FB1BA24D-A002-4848-BEA0-14F01B8AEC0F.mp4` 並確認分段有效；同時回報尾端無聲，因此不代表切段音訊已驗收。
- [ ] **即時音量驗收**：開啟可控錄製，錄製途中分別調整 App／麥克風音量；回放確認各自音軌混合效果有變化，無需重開錄製。
- [ ] **推流失敗保留錄製驗收**：以推流並可控錄製模式連到不可用的 RTMP 端點，失敗後持續錄製，再停止並確認檔案可播放。
- [ ] **意外中斷恢復驗收**：使用測試錄影強制終止 App，重新開啟後確認已完成片段可播放，最後未完成片段可辨識且不冒充完成檔案。
- [x] 分段群組清單、手動／停止後自動合併（保留來源），及明確錄影畫布寬高。
- [x] **晚到與跨界音訊處理**：`SegmentedRecordingRouter` 已把寬限期間內的晚到音訊交回前段，跨邊界 PCM 由 `RecordingPCMSlicer` 切分；已有對應測試，通過結果與實機音畫同步另驗收。
- [ ] **無縫切段驗收／改善**：跨多個分段播放或合併後，檢查邊界沒有新增靜音、重複音訊或影音偏移；現有路由仍有晚到丟棄條件，不能保證任意延遲皆無損。
- [ ] **片段容量上限**：目前只有 1／2／5／10 分鐘時長選項；尚未提供「每段最多多少 MB」的設定及切段策略。
- [ ] log-54 回歸驗收：確認尾端約 4.7 秒無聲問題、晚到音訊與跨段 PCM、群組合併接縫及雙 Writer 資源峰值。
- [ ] 原生 SCRecordingOutput 模式的獨立音量控制（目前只有可控錄製支援）。

## 本地錄影錄後壓縮

- [x] 設定入口與收尾接入：HEVC／H.264、目標碼率、尺寸及 FPS，失敗保留原檔。
- [ ] Xcode／實機驗收：長影片、AAC 音畫同步、單一／多段方向、HEVC／H.264、取消、空間不足、HDR 拒絕與未縮小時保留原檔。
- [ ] 既有錄影手動重試、進度與取消入口，以及程序遭終止後的轉碼暫存檔回收。

## 子母畫面聊天室

- [x] 測試 PiP 狀態由服務持有，離頁持續；主頁可停止，系統關閉／啟動失敗清理及跨服務互斥已接入。
- [ ] 測試 PiP 跨頁／回前景狀態、系統關閉、啟動失敗及兩組交替啟動實機驗收。

- [x] 實現聊天室畫面以 PiP (Picture-in-Picture) 方式呈現
- [x] 確保聊天室訊息即時更新與渲染
- [x] 改善子母聊天室性能：回全 CPU 渲染、移除未使用 GPU/CI 路徑、快取 frame metadata 並降低活動 FPS

- [x] 保活模式更新間隔可設 1–60 秒，預設 5 秒。
- [x] 一般聊天室時間刷新可選 1／2／5 秒；新增「降低聊天室動畫頻率」，活動／動畫由 6／16 降為 3／8 FPS。
- [x] 時間文字分桶快取與單張靜態聊天圖層快取；動畫／內容／尺寸變更失效，停止釋放。
- [x] 時間列上移、移除額外黑底；次要訊息提供一般／分段／隱藏；單行提示最多 4 頁、每頁 2.5 秒，可選頭貼，不進主要佇列。
- [x] 計時器併入直播狀態列並靠左；系統控制列顯示時左右避讓，全隱藏時使用 contentLeading；提供「隱藏控制列時上移」精簡版面開關。
- [x] 次要提示邊緣遮罩只在幾何變更時更新，無續段時移除 mask；沒有頭貼時不再建立空 avatar layer；訊息左右界線依實際頭貼／禮物計算。
- [x] 主要聊天與次要提示／次要聊天顏色可調（`pipMainTextColor`／`pipSecondaryTextColor`）；次要預設由 lightGray 提亮為 `#DBDBDB`，現有圖層會就地更新。
- [ ] **PiP 文字顏色驗收**：ColorPicker 即時套用、主要／次要文字與頭貼／頁碼共存、不同背景對比；狀態列與現在時間不受影響。
- [ ] **PiP 實機排版驗收**：小／大視窗檢查時間列、次要提示及主要聊天不重疊；本次新增的計時器併列、分段換頁、頭貼與精簡版面也要逐項確認；快取前後方向與文字一致，動畫結束不殘留舊圖。
- [x] PiP 固定性能摘要直接寫本機日誌，一般每 5 分鐘、失敗／背壓最快 1 分鐘與停止尾段回報，不依賴總日誌／PiP 詳細開關；包含耗時、排程延遲、重用與背壓，待實機核對。
- [ ] **PiP 排程與資源驗收**：關閉總日誌與 PiP 詳細日誌後，確認仍有 PiPPerformance 週期／停止尾段；逐一切換時間刷新與動畫設定，確認新訊息提前更新、停止重啟正常；比較重繪／送幀計數、CPU 與記憶體，不將降低 FPS 直接視為省電已驗證。
  - 2026-11-07 日誌已出現 `scheduleStopped`：attempts=99、redraws=90、work mean≈5.17ms、pool≈2.75MB；設定切換與長時間週期仍待。
- [ ] **PiP 時間圖層進一步快取**：目前已快取文字與靜態聊天室，時間／狀態圖層仍在合成時繪製；評估獨立圖層快取，須包含狀態、觀眾數、重連與版面失效條件。
- [ ] **次要事件分類／合併**：協定提供明確事件類型後，再合併加入通知；不可僅憑 isMain=false 猜測事件。切換模式不回溯刪除已入列訊息。

- [x] 修正正式 renderer 與 UIKit 預覽座標轉換；縮小控制鈕示意，計時與狀態分列，重整測試頁且移除測試 TTS 副作用。
- [ ] 新版預覽與 PiP 對照：一般／贊助圖層方向、長狀態／高人數、重連及次要提示不重疊；分段頁碼、頭貼與精簡版面也要對照；系統按鈕尺寸僅示意，須測不同視窗大小。

## App Group 的替代方案

- [x] 使用 Socket 同步擴展之間的參數變化
- [x] 研究替代 App Group 的資料共享方法（目前使用 Socket 替代）

## 視頻碼率分析

- [x] 視頻選取（相簿 / 檔案 App）
- [x] 詳細碼率資訊展示
- [x] 碼率圖表化（Swift Charts）
- [x] 手動單檔壓縮頁：相簿／檔案匯入、H.264／HEVC、碼率／長邊／FPS、音訊選項、進度取消、文件共享另存與原檔保留。
- [ ] 手動壓縮 CI／實機驗收：原檔 bytes 不變、方向／音訊／VFR、取消、不支援格式、磁碟不足與分享結果。
- [ ] 手動壓縮後續：批次、背景續跑、任務歷史、目標大小及完整本地化；詳見 `Docs/development/VIDEO_COMPRESSION.md`。

- [x] 壓縮另存測試改用固定合成影片，保留原檔比對並新增時長與解碼檢查（3b93d12）。
- [ ] **壓縮測試 CI 回歸**：確認測試 bundle 含樣本，手動碼率與系統品質兩案例皆完成；本機語法檢查不等同 iOS 測試通過。

## Live Activity / 動態島

- [x] **動態島接入**：`liveAPPWidget/LiveActivityWidgetBundle.swift` 已提供 DynamicIsland，Widget target 已引用 LiveActivityKit 並嵌入主 App。
- [ ] **動態島實機驗收**：確認支援裝置上的展開／精簡顯示及開播、停播生命週期。
- [x] **開播/停播整合**：於實際開播／停播路徑接入 `StreamActivityManager.shared.startStreamActivity()` / `endStreamActivity()`

- [x] 獨立即時動態設定入口、預設關閉的全局開關及 1／5／10／15 分鐘更新，預設 5 分鐘（70b1896）。
- [x] 系統計時、摘要取樣時間、依週期調整過期時間，取消任務與啟動世代隔離；ScreenCaptureKit 重連保留活動與原始計時。
- [x] 已核對每秒跳動來自 `Text(_, style: .timer)`，不是 `activity.update`；摘要仍依 `LiveActivitySettings.interval` 與事件 `refreshStatus()`。
- [ ] **新版 LiveActivity CI／實機驗收**：執行設定測試；直播中改間隔、關閉／重新開啟、重連恢復及啟動後立即停止，確認不重複建立、不重設計時、不停止後復活。背景暫停不保證準時更新。

## 本地化（Localization）

- [ ] 尚未完整搬移的字串（詳見 [localization.md](Docs/localization.md)）：主設定頁舊版 PIP 深層欄位、推流設定頁 RTMP 表單欄位與提示、TTS 設定頁與可用語音清單、設備資訊／日誌／音量／碼率分析頁、debug log／socket log／開發者提示文字

## 待確認 / 待量測（2026-09 自各文件彙整）

- [ ] **斷音根因尚未確認**：`align()` 單位不一致已被推翻回退，改由 AHealth 量測指標判斷（見 [replykit-core-fixes-summary.md](Docs/replykit-core-fixes-summary.md) 的「根因再確認」）
- [ ] **GPU 輸出成本尚未量測**：freeze snapshot 省下 `CVPixelBufferCreate`，但每幀仍建立 texture wrappers 與 format description，端到端效能未量測（見 [video-output-pool-lifetime.md](Docs/video-output-pool-lifetime.md)）
- [ ] **overlay 合成合併**：把 overlay 合成併進 `rotateNV12_bilinear` / `rotateNV12_bicubic` kernel；已評估為不優先（見 [overlay-scene-config.md](Docs/overlay-scene-config.md)）

## ScreenCaptureKit 接入（iOS 27）

推流與可控錄製已接入部分畫布、疊加與音量處理；系統直接錄製的支援範圍不同。以下依實作路徑列出，避免把部分缺口誤認為整套功能尚未接入；另見 [接入文件](Docs/screencapturekit-integration.md)。

- [x] **ScreenCaptureKit 畫面加工**：`ScreenStreamVideoRotator` 已處理固定左轉／不旋轉、畫布縮放、留黑邊或裁切填滿；推流使用 `StreamFramePolicy`，可控錄製可指定寬高。這是目前 SCK 路徑的實作，不代表已與 ReplayKit 合併成同一 GPU 核心。
- [ ] **跨來源共用影像核心**：評估並抽出 ReplayKit／ScreenCaptureKit 可共用的影像處理實作；動態方向與實機比例驗收另列，不以此項阻擋現有固定畫布功能。
- [x] **時間疊加層**：`ScreenOverlayComposer` 已依共用 Overlay 設定產生時間圖層，以輸出畫布定位；設定變更或秒數改變時重建快取。
- [ ] **其他浮水印與 Overlay**：盤點時間層以外的圖層並逐項接入；目前不能宣稱所有既有浮水印／覆蓋內容皆與 ReplayKit 一致。
- [ ] **共用音訊處理器**：接入既有 AudioProcessor、降噪、AGC 與回音處理，驗證系統聲音與麥克風雙軌。
- [x] **音量即時更新**：`prepareMediaPipeline` 的工作每 200 ms 檢查 appVolume／micVolume，變更後套用 Mixer；推流與可控錄製共用，系統直接錄製不支援。
- [ ] **其餘設定即時更新**：使用者修改目標碼率、畫布、旋轉或編碼設定後的直播中套用仍需設計；目前多數於啟動時讀取。既有自適應碼率不等於設定頁修改已即時生效。
- [ ] **HEVC**：接入編碼選項、伺服器能力協商及 H.264 回退，目前新路徑固定 H.264。
- [x] **基本 RTMP 畫面推流實測**：使用者已確認 ScreenCaptureKit 成功推到本地 SRS，並提供拉流位置；此結果確認畫面發布可用，音訊、方向與長時間同步分開驗收。
- [ ] **iOS 27 實機驗收**：系統授權／取消、背景與跨 App、靜態畫面、旋轉、分享選項變更、停止重開。
- [ ] **音訊共存驗收**：PiP／TTS 啟停、麥克風開關、耳機切換及來電中斷；確認 Audio Session 能正確還原。
- [ ] **資源與網路量測**：相同輸出設定比較兩種來源的 CPU、GPU、記憶體與延遲，驗證慢網路與重連。

## ScreenCaptureKit 本地錄製

- [x] 接入只推流／只錄製／推流並錄製；只錄製不依賴 RTMP。系統直接錄製不建立處理用 Mixer；可控錄製會建立 Mixer、樣本佇列與 Writer，即使沒有推流。
- [x] 接入 SCRecordingOutput、MP4／H.264、錄製進度及完成回呼；未完成檔案保留並標記。
- [x] 加入本地錄影列表、播放、分享／匯出、存入照片與刪除。
- [x] 分開處理推流與錄製失敗，新增模式／收尾／重啟核心測試及中文 API 文件。
- [x] **可控錄製接收處理結果**：`SegmentedRecordingSink` 掛載 Mixer，接收目前已實作的旋轉／畫布／時間層與混音音量；與 RTMP 分別編碼，不是直接保存 RTMP 壓縮封包。
- [ ] **未接入的處理效果**：其他 Overlay 與降噪／AGC 等完整處理器仍見「ScreenCaptureKit 接入」，不能將可控錄製視為已支援全部 ReplayKit 效果。
- [ ] **系統直接錄製處理後內容**：SCRecordingOutput 仍錄製系統擷取輸出，不經上述 Mixer；若需要加工畫面與獨立音量，目前應使用可控錄製。
- [x] **基本本地錄影產出實測**：使用者已提供 `2A565D3D-CEB4-418A-92F4-536EC69DF7C5.mp4` 並確認來自 ScreenCaptureKit 本地錄製；後續方向問題另列驗收，不再將基本錄影產出列為未確認。
- [ ] **錄影剩餘實機驗收**：iOS 27 背景／長時間錄製、立即停止、磁碟不足、斷網、完成回呼逾時、App 終止復原、App 內播放分享與照片權限。Xcode 27 首次建置已確認，見「自動測試與發布驗證」；後續修改仍需對應版本的 CI 結果。
- [ ] **雙輸出成本量測**：比較只推流、只錄製、推流並錄製的 CPU／GPU、記憶體、溫度與續航。

## 自動測試與發布驗證

- [x] `liveAPP` shared scheme 明確加入 `liveAPPTests`。
- [x] 新增 PR／push／手動可執行的單元測試 workflow，保存 `.xcresult` 與日誌。
- [x] 發布 workflow 先執行相同 commit 的單元測試，成功後才建置及封裝。
- [x] **首次 CI 實跑**：hosted runner 已完成建置與 `liveAPPTests` 執行；2026-10-05 由使用者確認。
- [x] **Xcode 27 CI 覆蓋**：Xcode 27 CI 與 ScreenCaptureKit 建置路徑已實跑，2026-10-05 由使用者確認。模擬器執行核心單元測試；ScreenCaptureKit 實機限定路徑由裝置建置涵蓋。
- [x] 模擬器 selector 改用已安裝 runtime、SDK 同版本優先、標準機型排序與開機 fallback；9 個 selector 測試。
- [x] Archive concurrency 不再取消進行中建置，避免接近完成的 archive 因新 tag 白費；新觸發只排隊並取代較舊 pending。
- [ ] 下一次 CI 驗證新選機與 fallback，特別是 iPhone Air 開機失敗、27.2 runtime 缺失與全新裝置重建。
- [ ] 若需要讓最新 tag 更早開始，評估在 archive 啟動前跳過已被新 tag 取代的工作，而不是取消已開始的建置。

## AltStore 來源

- [x] 來源改由 Release 附件提供，固定 `releases/latest/download/AltStoreTest.json`；`version`／`buildVersion` 取自 Info.plist、`size` 取 IPA bytes、What's New 取最近 10 筆 commit。
- [x] `update_altstore_source.py` 與 7 個測試；repo 樣板不再由 CI 改寫。
- [ ] **首次 Release 附件驗收**：確認 `AltStoreTest.json` 已附上、固定 URL 可下載、版本欄位與 IPA 一致，AltStore 顯示多行 What's New。
- [ ] 版本號未遞增時 AltStore 不會提示更新；目前刻意不自動改 `MARKETING_VERSION`／`CURRENT_PROJECT_VERSION`，需要時另立版本遞增方案。

## TTS 配置分享實作與驗收

- [x] JSON 匯入／匯出、合併／取代、自動備份、逐條啟用與替換排序已實作。
- [x] 匯入流程改用文件副本與背景協調讀取、頁內預覽及階段日誌；移除固定延遲和接續彈窗。

- [ ] **iOS 匯入／分享實機驗收**：檔案 App／iCloud 選取 JSON、取消選取、Documents 匯出及分享、合併衝突、逐條開關、拖曳排序與備份還原；目前 Foundation 邏輯測試及 Swift 語法檢查已通過。

## 建置資訊實作與驗收

- [x] 已加入 BuildInfo 產生流程與主 App 建置資訊讀取／顯示。

- [x] **Xcode／CI 建置資訊產物驗收**：使用者確認實機建置資訊有效，提供 `21a00d1e-bdef-496c-9e66-78d9468b52ff.txt` 作為證據。GitHub Actions run `37225832641` 的 Release／iphoneos 產物顯示 Xcode 27、SDK 27.0、App commit `dd59534`、產物識別碼與建置時間；HaishinKit checkout 與鎖定 commit `d1af6c5` 相符（2026-10-05 核對）。
- [x] **啟動日誌建置資訊驗收**：使用者提供的啟動日誌完整輸出 `[BuildInfo]`，包含 App commit `ce7f7a2`、乾淨原始碼狀態、相符的 HaishinKit checkout／鎖定 commit `d1af6c5`、產物識別碼 `fdfd3005-0a9f-414b-a278-0984c176426f` 與 CI run `37227708511`（2026-10-05 確認）。此為較前項更新的產物，兩份證據分別確認建置資訊與啟動日誌有效，不視為同一產物的交叉比對。

## ScreenCaptureKit 方向實作與驗收

- [x] 本地錄影已加入方向事件收集、固定方向轉正及多方向收尾處理；失敗保留原片。

- [ ] **本地錄影轉正實機驗收**：固定直向／左右橫向、途中多次轉向、音畫同步、既有矩陣避免重複旋轉、缺少附件提示、長片背景收尾及儲存空間不足保留原片。
- [x] **RTMP 固定方向轉正**：已加入推流左轉 90°／不旋轉選項與即時像素處理。
- [ ] **RTMP 動態方向轉正**：依 ScreenCaptureKit videoOrientation 自動切換；目前僅固定方向。

## 主頁排版與金鑰顯示實作與驗收

- [x] 自適應單／雙欄、依工作模式隱藏推流設定、進階控制收合。
- [x] 金鑰預設遮蔽、手動顯示與離開／背景自動隱藏；移除配置日誌的金鑰。

- [ ] 在 iPhone、iPad 與大字體模式確認單／雙欄、開播與停止操作。
- [ ] 確認只錄製隱藏推流設定，以及金鑰在關閉表單、App 背景返回後恢復遮蔽。

## App 圖示個性化與診斷

- [x] PersonalIcon 明確 iPhone／iPad 尺寸、設定頁切換、`Exp3.png` 原稿與 appiconset／預覽同步。
- [x] 圖示頁宣告診斷與複製；CI 封存與最終 IPA 包體報告、`inspect_app_bundle.py`、`app_icon_tool.py` 及對應測試。
- [x] **CI 圖示宣告檢查修正**：實際 archive 仍是 `CFBundleIconName` + Assets.car；檢查改為接受此標準形式，並仍要求 iPhone／iPad 都有 PersonalIcon 宣告。
- [x] 包體報告新增「套件內容」與「預期排除清單」；`Scripts/package_exclusions.txt` 列出 18 個開發檔／`.last_build`，任一被包含就失敗並列出路徑；`AudioProcess.swift.new` 與 `.last_build` 已排除在 target 外。
- [x] App 圖示診斷補上 version／build／UIDeviceFamily、`CFBundleIcons` presence 與 `CFBundleIconName`；有 name 時不再誤報缺 PNG，並顯示 `appRevision`／`buildID`／`ciRun` 以辨識實際安裝產物。
- [ ] 用 17.3.8 IPA（commit `7a2dae`）重裝，確認診斷的 PersonalIcon / CFBundleIconName 與 commit 正確；若仍空白，再查簽名工具是否替換 Info.plist。
- [ ] 下一次 archive 驗證修正後的圖示檢查、18 項排除狀態與包體報告。
- [ ] **iPad 圖示宣告驗收**：安裝含替換圖示的新建置，確認診斷的 version/build 與 CI IPA 一致、兩個 CFBundleIcons presence 為 true；若重簽後仍為 false，比對簽署前後 Info.plist。
- [ ] **App 圖示實機驗收**：iPhone／iPad 切換、恢復預設、`supportsAlternateIcons`、重新開啟 App 後目前標記與診斷內容。
- [ ] 16 個開發腳本／`.bak`／`.edit` 仍以 pbxproj membership exceptions 排除；若清理 repo，需另案移動或刪除。

## RTMP 樣本與設定匯入

- [x] 內建樣本移到 `liveAPP/RTMPPresets.json`（只含 URL）；使用者樣本 `rtmpUserPresets`、存目前 URL、刪除、匯入／匯出 JSON、host 改變清空金鑰，並納入設定備份。
- [x] `RTMPPresetStoreTests` 覆蓋驗證、持久化、去重、匯入、匯出與就地更新名稱／URL。
- [x] 使用者樣本可在管理清單編輯顯示名稱與 RTMP URL，或左滑刪除；快速套用仍保留。
- [ ] **樣本實機驗收**：檔案 App 匯入／匯出、重複或錯誤 JSON、50 筆上限、選單分組、管理清單編輯／刪除與切換 host 後的金鑰提示。
- [ ] 推流配置（含 `streamKey`）專用匯入；目前可先用完整設定備份的敏感匯出／還原。

## 錄影方向選項與切換回歸

- [x] 自動左右映射修正，提供不修正／左右 90°／180°，每次擷取固定設定。
- [x] 主頁雙欄固定寬度，新增主要控制與方向選項三語本地化。
- [ ] 實機驗證自動左右橫向、五種方向選項及不修正保留原始影片。
- [ ] iPhone／iPad 切換來源與工作模式、大字體及三種語言下確認版面穩定。

## ScreenCaptureKit 推流錯誤診斷

- [x] log-58：主 App 重連期間更新發布狀態，停止／舊工作回呼不再恢復直播；等待新輸出才標示已發布。
- [x] log-58 底層心跳改進與警告修正已提交至 `99348ac4`，使用者確認底層測試通過；主 App 兩份套件鎖定已一致接入。
- [ ] 主 App 接入後執行 CI 與斷線／重連／停止實測；詳見 [調查文件](Docs/development/LOG58_DISCONNECT.md)。
- [x] 影片向前大間隔保留策略已接入；後續驗收統一見「影片停頓後的影音同步驗收」。SRS 心跳無回應根因不視為隨此修正已確認。

- [x] 分開擷取與發布階段，加入具名錯誤、底層原因及敏感資訊遮蔽。
- [x] **錯誤碼 5 與失敗階段可觀測**：使用者於 2026-10-05 提供實機日誌，包含 `stage=rtmp.connect`、`requestTimedOut`、錯誤 domain／code，並顯示端點 `192.168.0.102:1936` 與 `portSource=explicit`；已確認連線逾時及指定端口。
- [ ] **連線失敗根因驗收**：以新版握手／傳輸診斷定位失敗端點停在 TCP、S0S1、S2 或 connect 回覆的哪一階段；先前錯誤碼 5 日誌只證明逾時，不能據此判定伺服器或網路根因。

## 日誌頁閱讀體驗

- [x] 等級顏色與模組標籤、搜尋篩選、複製篩選原文及追尾調整。
- [ ] 實機確認大量日誌、深淺色與大字體、選取複製及切頁返回。
- [ ] 逐步將跨模組日誌寫入改為結構化等級與來源，取代舊文字相容分類。

## 主日誌檔案歷史

- [x] 主 log.txt 分頁、位移索引、前景最新更新與閱讀位置保留。
- [x] 完整檔案範圍搜尋、結果前後文、取消及清空確認。
- [ ] 實機驗證切頁／背景返回、歷史翻頁、搜尋跳轉與裁切後重新定位。

- [x] 日期範圍診斷匯出、主日誌輪替封存與擴展交接已實作；匯出入口改為獨立 sheet。
- [x] **診斷匯出已有實機產物**：2026-11-05 提供 00:00–00:37 範圍檔案，可讀取且摘要顯示疑似日期解析失敗為零；不代表所有日期格式及封存邊界均已驗收。
- [ ] **封存與匯出回歸**：跨午夜／跨封存檔匯出、長時間背景寫入、分享取消與寫入失敗；確認沒有漏行、重複交接或憑證未遮蔽。

## 擷取音訊收尾

- [x] 移除強制揚聲器與失敗收尾的排他音訊還原，補上音訊生命週期診斷。
- [ ] 實機測試推流逾時及正常停止不打斷外部影片，涵蓋麥克風開關、耳機及 PiP／TTS。

## 本地錄影資訊與分析

- [x] 完成錄影的軌道資訊、尺寸、FPS、碼率與直接分析入口。
- [x] 分析器只清理自身建立的暫存副本，不刪除錄影來源。
- [ ] 實機驗證旋轉影片資訊、碼率分析與返回／關閉後原片仍可播放分享。

## ScreenCaptureKit 推流方向與音訊可觀測性

- [x] 固定左轉 90°／不旋轉選項、GPU 像素轉正及有上限的輸出池。
- [x] 主頁連線階段、實際編碼器格式、設定目標碼率與音訊封包取樣狀態。
- [x] 來源音訊 ASBD／PCM 可讀性與 Mixer 實際交付計數診斷。
- [ ] 實機確認左轉畫面、letterbox 比例、色彩與旋轉資源用量。
- [x] **Mixer 與編碼音訊格式已取得**：2026-10-20 實機截圖顯示 Mixer 為 LPCM、48000 Hz、2 聲道、16 bit、interleaved；編碼輸出為 AAC、48000 Hz、2 聲道。此為 Mixer／編碼端資料，不能反推所有原始擷取輸入格式。
- [ ] **無聲與音畫同步驗收**：對照來源音訊診斷與拉流檔案，確認實際可聽到系統／麥克風聲音並保持同步；有 AAC packet 不代表播放結果已驗收。
- [x] **結構化編碼及 socket 傳輸快照實機顯示**：ScreenCaptureKit 截圖已顯示影音壓縮格式、累計輸出及 socket 本機完成／待完成／失敗量；格式由共用快照提供。
- [ ] **診斷剩餘缺口**：Mixer 錯誤的共用結構化回報，以及 RTMP 訊息／chunk／ACK 統計仍需補齊；既有格式日誌相容解析與實際快照不可混為同一來源。
- [ ] 補齊伺服器音訊擴充能力回覆解析；未回報時保持未知。

## 推流音訊碼率

- [x] 共用自動／128／96／64 kbps 選項，兩條推流路徑下次開播套用。
- [ ] 實機驗證兩種來源各選項的 AAC 音軌、重開播設定與伺服器播放相容性。

## 開發文件索引

- [x] 本機功能／API／文件／近期改動索引與清單連結驗證。
- [x] DocC 初始目錄與手動 CI 工作流程。
- [x] DocC workflow 新增 `changes` preflight：沒有 `.docc`／公開文件變更時跳過 macOS docbuild；手動觸發仍會重建。
- [ ] 下一次 Swift-only 與 docs-only push 驗證 skip／run 與 Pages 部署。
- [ ] 首次 Xcode DocC 建置與 archive 閱讀驗收。
- [ ] 擴充功能清單覆蓋其他模組，補齊 API 語意文件及底層 DocC 連結。

## 底層 RTMP 傳送診斷接入

- [x] 底層 checkout 修正失敗回呼計數，新增 transportDiagnostics() 與 DocC 文件。
- [ ] 底層 Apple SDK 建置、失敗傳送及舊回呼跨重連驗證。
- [x] 底層提交發布後更新 App 套件鎖定，兩種來源接入同一診斷模型與前端；主 App `d418d58` 已包含共用快照、設備頁及兩份套件鎖定。
- [ ] 補齊影音訊息／RTMP chunk 計數、ACK 及裝置負載統一展示。
- [x] 底層 DocC workflow 首次成功建置與 GitHub Pages 部署驗收：使用者已提供 `rtmptransportdiagnostics` 文件頁並確認 DocC 有效；不代表每次後續部署均已驗收。

## log-49 後續驗證

- [x] 區分診斷來源、標示過期，新增擷取資源與收尾階段日誌，設定單視窗。
- [ ] CI／實機驗證單視窗產物設定與斷線重連、停止後記憶體釋放。
- [ ] 定位 Mixer 音訊輸出停滯與無界 PCM 緩衝，審查套件更新；詳見 [調查報告](Docs/development/LOG49_DIAGNOSTICS.md)。
- [ ] 擴展診斷手動重連：獨立控制通道、回覆／逾時及連線世代隔離；不重啟推流。

## 串流格式與傳輸可視化

- [x] 雙來源 Mixer 實測格式、編碼設定、影片事件、Socket 傳輸統計接入設備資訊。
- [x] **實際編碼格式接入**：底層 `7ce4304b` 提供 encodingDiagnostics()，主 App `d418d58` 已接入雙來源及設備頁；實機驗收仍見「共用設備診斷」。
- [ ] **RTMP 封裝與對端確認統計**：補 RTMP chunk／音訊訊息／ACK 結構化接口與 UI。現有 audioPackets 是壓縮音訊 packet，不能替代 RTMP 訊息數；本機完成量也不能替代伺服器 ACK。
- [x] **ScreenCaptureKit 格式與傳輸畫面實機驗收**：2026-10-20 截圖可見連線世代 1、待完成 0 bytes、本機完成 22097022 bytes、失敗批次大小 0 bytes；只確認本機統計顯示，不代表伺服器 ACK 或成功解碼。
- [ ] **其餘傳輸可視化驗收**：ReplayKit、停止、重連世代與資料過期；log-58 已發現重連時仍顯示已發布，本批修正後需另行實測。CI 與接入範圍見 [接入說明](Docs/development/STREAM_DIAGNOSTICS.md)。

- [x] RTMP 最新入列嘗試與首次嘗試／首次成功分開呈現；起始紀錄收合，來源與相對 PTS／DTS 分列，缺值不冒充零（1c740e4）。
- [ ] **RTMP 明細新版實機驗收**：最新序號／時間持續前進、首筆紀錄固定、拒絕入列標示正確；窄視窗、大字體及收合操作正常。成功入列不代表伺服器收到。

## 主頁模組整理

- [x] 第一批拆分主頁、RTMP 表單、廣播按鈕及共用型別，補中文註釋與模組索引。
- [ ] CI／實機驗收分頁、配置保存、金鑰隱藏、版面、擷取開始／停止與前背景行為。
- [ ] 第二批整理設定頁及音量頁內部區塊；見 [維護入口](Docs/development/HOME_MODULES.md)。

## 第二批編碼與診斷

- [x] 拆出編碼卡片與能力查詢，移除 H.264 自製 Level 推算，兩種推流来源共用解析。
- [x] 接入 Mixer PCM 取樣率數值；保留新增健康欄位的 nil 與舊訊息相容性。
- [ ] Xcode CI 執行新增 Swift 測試；實機驗證一般／低延遲清單、舊設定、兩種來源開播及側載鎖限制。
- [ ] GPU 超標視窗計數：底層逐幀量測、閾值／樣本數／視窗一起傳送；不以 timeoutDelta 代替。
- [ ] 音訊分階段延遲量測與來源取樣率；totalLatencyMs 保持未提供。
- [ ] HEVC 裝置能力列舉，以及實際編碼輸出與要求設定的核對。

## Socket 維護

- [x] 拆出純資料轉換與日誌格式，補充生命週期註釋、null 相容與音量邊界測試。
- [ ] 全面檢查 SocketServer 佇列隔離、共享 encoder／decoder 與 UI 狀態更新；目前仍為 @unchecked Sendable。
  - 2026-11-07 初查：`decoder` 只在接收 queue 使用；`listenerStatus`／`isStopping` 等 UI 多已派回 main。
  - [x] 共享 `JSONEncoder` 已收斂：`queueSend`／`sendTo` 在 queue 內編碼，`dictionary(from:)` 改用區域 encoder。`@unchecked Sendable` 的全面狀態稽核仍待完成。
- [x] 評估每連線待送佇列上限與背壓，避免慢速連線無限累積資料。
  - 2026-11-07 已抽 `SocketSendQueuePolicy`（1 MiB／128 筆）；一般訊息超限時記錄並關閉慢連線，外部日誌批次仍走可丟棄的 `ExternalLogPolicy`。同時移除不會被重放的 `pendingFailedPayloads`，避免移除連線後保留待送資料。
  - 仍待 Apple 實機驗證慢速工具、送出行為與關閉連線的日誌。

- [x] 統一 Socket 被動恢復入口，移除裸 observer 指標，停止／端口切換使舊工作失效。
- [ ] Apple 整合驗收：Darwin 重複提示、setup／waiting 保留、stop 後提示、占用端口重試、切換端口中停止與物件釋放。

## 影片停頓後的影音同步驗收

- [x] 主 App 兩份套件鎖定更新至 `03c77703`，接入保留影片真實向前時間間隔的底層修正；底層 CI 通過。
- [ ] 主 App CI：確認新套件可建置並通過單元測試。
- [ ] ReplayKit／ScreenCaptureKit 實機：持續推流並觸發數秒畫面停頓，核對恢復後沒有因時間戳縮短造成新增影音偏移；保留 App 日誌及未經轉碼的接收端樣本。來源時鐘重設與伺服器轉碼造成的偏移需另行判讀。
- [ ] **2026-11-07 02:58 音訊 discontinuity 追查**：ScreenCaptureKit 推流約 1.5 小時後，系統音訊 track0 的 `discontinuities` 由 1→2、`spanMinusContentSeconds` 由 +0.020→-0.127，`CaptureCallbacks.audio.regress=1`；同一時刻 video inFPS 短暫 60→47.8，`publish avOffset` 約 -0.2s。RTMP transport `failedBatches=0`、queue 為空，mic track1 乾淨；影片 PTS regress=0。3.1 秒 video max gap 的 lastDiscontinuity 是早期 7154.7，不是這次起點。
  - [x] `ScreenAudioProbe` 已加逐筆 `[CaptureAudioAnomaly]`（PTS 回退或 gap >0.5s，含 prev/current/delta/frames/rate）。
  - [ ] 底層 `RTMPTimestamp.update` 以 wire `updatedAt` 比對來源；音訊 `preferredDelta` 對負向 gap 只做每包 ≤5ms 慢速修正，`allowJump` 只處理正向 >500ms，`sourceRegressions` 不參與決策。需確認 RTMP 使用的 mixed 音訊是否帶入此 gap，再決定 drop／rebase／補靜音或調整策略。

## 共用音量監測與閒置比較

- [x] ScreenCaptureKit 分軌混音前與混音後 RMS 接入音量頁，區分缺資料、過期、停止與靜音。
- [x] 本機 session 隔離、可見頁面限頻與多視窗可見登記；程序內記憶體基準與停止後差值。
- [ ] Apple CI：執行 AudioMeterTests；實機分別播放 App 音訊、說話、靜音、停止與重啟，核對來源音量和混音後值。
- [ ] ReplayKit 舊傳輸沒有 session／來源取樣時間；需擴展協定一起升級，才能拒絕跨連線延遲封包。目前收到時間只能用於 UI 過期判斷，本機 ScreenCaptureKit 持有期間會拒收 ReplayKit 值。
- [ ] 冷啟動不開播至少 60 秒後取得基準，再比較停止後 30／60／120 秒；背景暫停會延後採樣，以 stopElapsedSeconds 為準。
  - 2026-11-07 的 11MB cold baseline 太低；新冷啟動 process 的 warm idle 約 29.7MB（舊 process 109MB 是另一段累積狀態）。舊 process 停止後 49.7 秒仍 142.3MB，比它的 pre-capture 109.2MB 高約 33MB；需用新的 ~30MB warm idle 重做短開播停止比較。
- [ ] 進一步補各子系統持有量（診斷歷史、待處理工作等）；目前 footprint 差值不能歸因到個別物件，也不等於洩漏判定。
  - 上述 +33MB 不能在 PiP pool（約 2.75MB）解釋；需補聊天快取、日誌／診斷歷史、SCK／Metal 快取等持有量。

## 跨軌時間補償策略驗收

- [x] 兩份套件鎖定更新至 `6ac475ad`，接入移除自動影片補償及音訊跨軌重標；底層測試通過。
- [ ] 主 App CI：確認新版套件建置及單元測試通過。
- [ ] ReplayKit／ScreenCaptureKit 實機：核對 publish timeline schema=2、alignment=observeOnly、videoCompensation=0、audioResyncs=0，測試影音不同時開始、長停頓及重連；比對未轉碼接收樣本的聲畫內容，不以最新 PTS 差取代同步驗證。
- [ ] 底層共同時間原點：先核對來源時鐘與首包等待、單軌發布、後加入軌道及重連策略；目前仍各軌獨立歸零。
- [ ] 影格跨階段追蹤：保存原始擷取時間、各階段耗時及重複畫面標記，定位內容延遲來源。

## 分類文件靜態站

- [x] .changelog.toml 分組現有 Markdown，驗證路徑存在及唯一。
- [ ] 固定 ChangeLogKit 可安裝版本，接入既有 DocC workflow 的 site/project 子目錄；補首頁跳轉、觸發條件及子路徑連結驗收。

## PiP 續段退場

- [x] 聊天頂部裁切與續段漸隱，保留逐段閱讀，無效淡出時長回復安全值。
- [ ] 實機連送長訊息及圖片／表情：確認上一筆尾段柔和退出、完整新訊息清晰、時間區不受遮罩影響，最後一幀無殘留。

## 設定備份與共享錄影目錄

- [x] 自動白名單 JSON 備份、成功時間、分享、敏感資料選擇及還原預覽。
- [x] 下次啟動套用、還原前備份、錯誤檔整份拒絕，避免執行服務讀取半套設定。
- [x] 舊 latest 損壞或超過 2 MB 時不再阻塞輪替；寫入前檢查上限，oversized latest 有回歸測試。
- [x] 前景／背景切換只在有偏好變更時重新 capture（needsSave）；無變更不重寫檔案。
- [x] 本地錄影搬至 Documents/ScreenRecordings；搬移衝突不覆蓋，保留舊路徑供分享。
- [ ] Xcode／CI 執行 SettingsBackupTests（含新增 oversized latest）、RecordingStorageMigrationTests 與既有 RecordingLibraryTests。
- [ ] 實機：修改 TTS／PiP／Socket 設定，兩秒後檢查成功時間；由檔案取出 JSON，還原重啟後核對值。
- [ ] 實機：敏感匯出提示、一般備份排除金鑰、錯誤檔預覽失敗、待還原取消與背景補存。
- [ ] 實機：確認舊錄影搬移後仍可播放、分享、分段合併；三個資料目錄能在檔案中搬到 App 外部。
