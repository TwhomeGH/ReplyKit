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
