# TODO 待辦事項

集中管理全專案未完成／待處理的事項。

> 新待辦請寫在這裡，不要在各文件的角落另開 TODO 區塊；完成後改為 `[x]`（整批清理時可移除已完成項）。

## 子母畫面聊天室

- [x] 實現聊天室畫面以 PiP (Picture-in-Picture) 方式呈現
- [x] 確保聊天室訊息即時更新與渲染
- [x] 改善子母聊天室性能：回全 CPU 渲染、移除未使用 GPU/CI 路徑、快取 frame metadata 並降低活動 FPS

## App Group 的替代方案

- [x] 使用 Socket 同步擴展之間的參數變化
- [x] 研究替代 App Group 的資料共享方法（目前使用 Socket 替代）

## 視頻碼率分析

- [x] 視頻選取（相簿 / 檔案 App）
- [x] 詳細碼率資訊展示
- [x] 碼率圖表化（Swift Charts）
- [ ] 壓縮視頻轉碼功能，以最大化效益

## Live Activity / 動態島

- [ ] **動態島支援**：`LiveActivityAttributes.swift` 的 `StreamActivityDynamicIsland` 已定義但被註解；需在 Xcode 將 `ActivityKit.framework` 加入 target 的 Frameworks 後取消註解啟用
- [x] **開播/停播整合**：於實際開播／停播路徑接入 `StreamActivityManager.shared.startStreamActivity()` / `endStreamActivity()`

## 本地化（Localization）

- [ ] 尚未完整搬移的字串（詳見 [localization.md](Docs/localization.md)）：主設定頁舊版 PIP 深層欄位、推流設定頁 RTMP 表單欄位與提示、TTS 設定頁與可用語音清單、設備資訊／日誌／音量／碼率分析頁、debug log／socket log／開發者提示文字

## 待確認 / 待量測（2026-09 自各文件彙整）

- [ ] **斷音根因尚未確認**：`align()` 單位不一致已被推翻回退，改由 AHealth 量測指標判斷（見 [replykit-core-fixes-summary.md](Docs/replykit-core-fixes-summary.md) 的「根因再確認」）
- [ ] **GPU 輸出成本尚未量測**：freeze snapshot 省下 `CVPixelBufferCreate`，但每幀仍建立 texture wrappers 與 format description，端到端效能未量測（見 [video-output-pool-lifetime.md](Docs/video-output-pool-lifetime.md)）
- [ ] **overlay 合成合併**：把 overlay 合成併進 `rotateNV12_bilinear` / `rotateNV12_bicubic` kernel；已評估為不優先（見 [overlay-scene-config.md](Docs/overlay-scene-config.md)）

## ScreenCaptureKit 接入（iOS 27）

目前是基本全螢幕推流與本地錄製測試版，完整範圍見 [接入文件](Docs/screencapturekit-integration.md)。以下項目完成前，相關功能繼續使用 ReplayKit。

- [ ] **共用 GPU 處理核心**：抽出並接入自訂畫布、裁切／縮放與旋轉；驗證直橫轉換及輸出比例。
- [ ] **浮水印與 Overlay**：接入既有直播浮水印、文字／時間與其他覆蓋圖層，避免兩種來源行為不一致。
- [ ] **共用音訊處理器**：接入既有 AudioProcessor、降噪、AGC 與回音處理，驗證系統聲音與麥克風雙軌。
- [ ] **設定即時更新**：直播期間同步碼率、音量、畫布與支援的編碼設定；需要重建的設定須保留生命週期及世代隔離。
- [ ] **HEVC**：接入編碼選項、伺服器能力協商及 H.264 回退，目前新路徑固定 H.264。
- [ ] **iOS 27 實機驗收**：系統授權／取消、背景與跨 App、靜態畫面、旋轉、分享選項變更、停止重開。
- [ ] **音訊共存驗收**：PiP／TTS 啟停、麥克風開關、耳機切換及來電中斷；確認 Audio Session 能正確還原。
- [ ] **資源與網路量測**：相同輸出設定比較兩種來源的 CPU、GPU、記憶體與延遲，驗證慢網路與重連。

## ScreenCaptureKit 本地錄製

- [x] 接入只推流／只錄製／推流並錄製；只錄製不依賴 RTMP，也不建立推流 Mixer 與樣本佇列。
- [x] 接入 SCRecordingOutput、MP4／H.264、錄製進度及完成回呼；未完成檔案保留並標記。
- [x] 加入本地錄影列表、播放、分享／匯出、存入照片與刪除。
- [x] 分開處理推流與錄製失敗，新增模式／收尾／重啟核心測試及中文 API 文件。
- [ ] **錄製最終處理結果**：支援錄下經過 GPU 浮水印、畫布及音訊處理的最終推流內容；目前錄製 SCStream 原始擷取輸出，不套用 Mixer 音量。
- [ ] **錄影實機驗收**：Xcode 27 編譯、iOS 27 背景／長時間錄製、立即停止、磁碟不足、斷網、完成回呼逾時、App 終止復原、播放分享與照片權限。
- [ ] **雙輸出成本量測**：比較只推流、只錄製、推流並錄製的 CPU／GPU、記憶體、溫度與續航。

## 自動測試與發布驗證

- [x] `liveAPP` shared scheme 明確加入 `liveAPPTests`。
- [x] 新增 PR／push／手動可執行的單元測試 workflow，保存 `.xcresult` 與日誌。
- [x] 發布 workflow 先執行相同 commit 的單元測試，成功後才建置及封裝。
- [ ] **首次 CI 實跑**：確認 hosted runner 能建置並執行所有 `liveAPPTests`；目前只完成本地設定與靜態驗證。
- [ ] **Xcode 27 CI 覆蓋**：workflow 已指定 xcode-27／Xcode 27.0 並強制檢查 SDK 27；ScreenCaptureKit 在 iOS 為實機限定，模擬器單元測試不編譯此路徑，改由發布流程的裝置 archive 涵蓋 Apple SDK 編譯；待首次實跑確認。

## TTS 配置分享驗收

- [ ] **iOS 匯入／分享實機驗收**：檔案 App／iCloud 選取 JSON、取消選取、Documents 匯出及分享、合併衝突、逐條開關、拖曳排序與備份還原；目前 Foundation 邏輯測試及 Swift 語法檢查已通過。

## 建置資訊驗收

- [ ] **Xcode／CI 產物驗收**：確認 build／archive 的 App bundle 含 BuildInfo.json，App 與套件 revision 對應該次 checkout，實機關於頁、複製分享及啟動 log.txt 顯示相同資訊。
