# TTS 過濾器 JSON 匯入與匯出

## 使用方式

進入「TTS 朗讀 → TTS 過濾詞管理」。每條排除／替換規則旁有啟用開關，停用只略過處理，不刪除規則。替換規則依畫面順序執行，可按「編輯」拖曳調整。

- **匯出目前配置**：將完整過濾配置儲存至主 App 的 Documents，與 `log.txt` 相同目錄。完成後可按「分享最近匯出的配置」，或從檔案 App 的本機 App 目錄取用。
- **匯入 JSON**：從系統文件選擇器匯入副本，背景讀取並完整驗證後，直接在目前頁面預覽數量與衝突。取消預覽不更動設定。
- **確認合併**：保留既有順序，新規則追加至尾端；相同規則去重。衝突預設保留現有值，也可勾選採用匯入內容及啟用狀態。合併保留目前三個全域過濾開關。
- **確認取代目前清單**：改用匯入清單與順序，包含停用規則；套用檔案有提供的全域過濾開關，省略的開關維持目前值。空清單可以清空既有規則。

兩種匯入方式都會先備份目前配置至 Documents，備份寫入失敗就不套用。匯入成功後立即保存，影響後續文字過濾；不重建已在朗讀佇列中的內容，也不修改 TTS 總開關、語音、語速及訊息長度設定。

匯出檔名為 `tts-filters-日期時間-UUID.json`；備份為 `tts-filters-backup-日期時間-UUID.json`，不覆蓋先前檔案。要復原，可再次匯入備份並選擇取代。

## JSON 格式

可直接使用 [範例配置](examples/tts-filters.example.json)。

```json
{
  "version": 1,
  "blockKeywords": [
    { "word": "廣告詞", "enabled": true },
    { "word": "暫停排除的詞", "enabled": false }
  ],
  "replaceKeywords": [
    { "word": "FPS", "replacement": "每秒影格數", "enabled": true }
  ],
  "removeURLs": true,
  "removeEmoji": true,
  "removePureNumbers": false
}
```

| 欄位 | 規則 |
| --- | --- |
| version | 目前為 1；省略或 null 視為 1，其他版本拒絕匯入 |
| blockKeywords | 必填陣列；每條包含 word 與可選 enabled |
| replaceKeywords | 必填陣列；每條包含 word、replacement 與可選 enabled，依陣列順序套用 |
| word | 必填字串，不可為空字串或全空白；以文字直接比對，不是正規表示式 |
| replacement | 必填字串，允許空字串，代表移除匹配文字 |
| enabled | 布林值；省略或 null 預設 true，false 保留規則但不執行 |
| removeURLs／removeEmoji／removePureNumbers | 可選布林值；取代時才套用有提供的值，合併時維持目前值 |

例如訊息「目前 FPS 是 60」，套用範例後會送出「目前每秒影格數是 60」給 TTS 朗讀；聊天室仍顯示原文。將該規則的 `enabled` 設為 `false`，就不展開這個縮寫。

排除規則先執行，再依順序套用替換規則。規則是否重複以原字判定；同原字的替換內容或 enabled 不同，視為衝突。停用規則也參與去重與衝突判斷。

檔案內若同原字出現互相矛盾的內容或啟用狀態，整份拒絕匯入；完全相同的規則會去重。匯入檔與目前設定之間的衝突，才交由預覽頁選擇。

## 舊配置相容

仍支援既有的字串排除清單與 Dictionary 替換清單：

```json
{
  "blockKeywords": ["廣告詞"],
  "replaceKeywords": { "FPS": "每秒影格數" }
}
```

舊規則預設全部啟用。Dictionary 沒有可靠的執行順序，因此匯入舊格式或載入舊設定時，以原字的 Swift 字串排序建立固定順序。新版匯出一律使用帶 enabled 的物件陣列，後續匯入保留陣列順序。單一清單不要混用字串與物件元素。

## 驗證與限制

- 最多 2 MiB、排除與替換合計最多 10,000 條；停用規則仍計入數量。
- 非法 JSON、缺少必要清單、錯誤型別、空白原字或檔內衝突，都不更動設定。
- 不支援的第三方欄位不會自動轉成規則；請依本文件格式提供配置。
- 配置保存在原本的 `SpeechFilterSettings` UserDefaults，新增順序與停用狀態欄位；初始化載入及整批套用期間暫停逐欄寫入，完成後保存。

## 程式入口

| API | 返回與行為 |
| --- | --- |
| SpeechFilterConfiguration.decode(_:) | 返回完整驗證後的配置；失敗拋出中文錯誤 |
| encoded() | 返回新版 JSON Data，包含逐條 enabled |
| merging(_:useIncomingConflicts:) | 返回合併結果，不修改原物件 |
| conflicts(with:)／blockConflicts(with:) | 返回需選擇處理方式的原字清單 |
| write(to:backup:) | 返回已寫入的檔案 URL；失敗拋錯 |
| SpeechFilterManager.importConfiguration(...) | 先驗證、再備份、最後套用；返回備份 URL |
| SpeechFilterManager.configuration | 目前完整配置快照，包含停用狀態與順序 |

## 測試

11 項配置與管理器測試涵蓋舊格式、順序、非法輸入、衝突合併、enabled 往返、停用規則的實際文字處理、重啟保存、匯出及備份，以及備份失敗不修改設定。Windows 測試使用實際 Foundation 邏輯，暫存副本替換 ObservableObject／Published 宣告；不代表 SwiftUI、檔案選擇器或 iOS 分享已完成實機驗證。測試已加入 liveAPPTests，隨既有 workflow 執行。

## 匯入診斷

選檔後顯示讀取進度；讀取或解析失敗會在頁面保留錯誤提示。預覽不會再接續開啟另一個彈窗，也不依賴固定延遲。取消選取或預覽不修改配置。

部分文件供應商將 JSON 標記成一般檔案，因此選擇器容許一般資料檔；匯入時仍嚴格檢查 JSON 格式與 2 MiB 上限。請選取 JSON 配置，非配置檔案會顯示錯誤。

`log.txt` 的「TTS匯入」記錄開啟選擇器、選檔回呼、讀取／驗證結果與規則數，不記錄規則內容或檔案完整路徑。若只看到開啟選擇器而沒有回呼，表示尚未收到系統交付檔案；若已收到回呼但沒有完成記錄，需檢查文件供應商讀取階段。
