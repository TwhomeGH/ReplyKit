# 開發索引與 API 文件

## 開啟方式

雙擊 `Scripts/change_log.cmd`，點「功能／API／近期改動索引」。原有新增／修改變更紀錄功能保留。

也可執行 `python Scripts/change_log.py serve --no-browser`，依終端機列出的本機位址開啟 `/development`。搜尋包含功能狀態、Swift 宣告、文件內容。點宣告或文件可在瀏覽器閱讀帶行號的原始內容。

若要一起搜尋 HaishinKit，先設定環境變數 `REPLYKIT_HAISHINKIT_ROOT` 為底層 checkout 的絕對路徑，再啟動工具。不會自動下載、修改或更新套件。

## 程式結構

`Scripts/change_log.py` 與 `Scripts/dev_index.py` 只是相容入口（薄殼）；實作拆分在 `Scripts/changelog/` 套件：

| 模組 | 職責 |
| --- | --- |
| `changelog/storage.py` | ChangeHistory.md 解析、組版與讀寫 |
| `changelog/devindex.py` | 功能／API／文件／近期改動索引 |
| `changelog/server.py` | 本機 HTTP 伺服器與路由 |
| `changelog/cli.py` | 命令列（add／list／show／serve） |
| `changelog/assets.py` + `changelog/assets/` | 網頁資產載入與檔案 |

網頁樣式與行為全在 `Scripts/changelog/assets/`：`theme.css`（色票與共用元件，含深／淺色）、`index.*`（變更歷史）、`dev.*`（開發索引）、`file.*`（檔案檢視）。改版面或配色只需動這些資產，不必改 Python。各頁右上角可切換深／淺色（存在 localStorage，並跟隨系統偏好）。開發索引的 API 宣告註釋以 markdown 呈現，檔案檢視支援行號就地跳轉與高亮，不需重載。

## 各資料的責任

| 資料 | 來源與限制 |
| --- | --- |
| 功能／接入 | features.json：固定 ID、用途、兩種來源、UI、驗證狀態及檔案連結；人工維護 |
| API 宣告 | 掃描 Swift 宣告及相鄰文件註釋，只作定位；不是編譯器解析，不能完整辨識條件編譯、跨行宣告或呼叫關係 |
| 近期改動 | Git 最近 20 筆提交與未提交／未追蹤檔案；不推測變更的功能語意 |
| 版本 | App HEAD、鎖定套件 revision、選填底層 HEAD；不是已安裝 App 的 BuildInfo |
| DocC | 由 Xcode 編譯器與文件註釋產生；獨立於本機文字索引 |

搜尋結果最多先顯示 250 筆；文件搜尋內容上限為每份 100000 字元，檔案閱讀上限 2 MB。僅提供 Git 可見且未忽略的 Swift／Markdown，排除隱藏路徑；不提供任意本機檔案下載。

## 更新規則

新增或改變功能時，在同一筆變更更新 features.json；ID 保持穩定。ChangeHistory 可引用功能 ID 與相關文件。TODO 繼續集中管理未完成事項，索引提供入口，不複製完整待辦。

接入和驗收要分開描述。缺乏證據填「待驗證」，底層存在但上游沒接就明確寫出；不能只用「完成」概括。宣告索引由程式重建，不手抄函數清單。

執行 `python Scripts/test_dev_index.py` 驗證資料、失效連結、路徑限制與 HTTP 接線。Development index workflow 在 push／PR 執行相同檢查。

## DocC 建置

macOS Xcode 使用 Product → Build Documentation。另提供手動觸發的 DocC documentation workflow，使用專案既有 xcode-27 runner，產出 doccarchive、App revision、Package.resolved 與建置日誌，不自動發布網站。

目前只有 App 的初始文件目錄。HaishinKit 自己的 DocC、完整跨模組連結與詳細 API 文件覆蓋仍需後續補齊；本次未執行 Apple SDK docbuild，workflow 的首次成功產物仍待確認。Windows 的宣告搜尋不需要 Xcode。

## 文件（DocC）

這裡的「API 宣告」是**文字掃描**（收錄 func／型別／存取修飾的屬性／init，含多行簽名與相鄰 `///` 註釋），目的是在本機快速定位，不是 Swift AST，也不含呼叫關係。

真正的 Apple DocC（`.doccarchive`）**無法在 Windows 產生**：

- `docc` 工具鏈官方只隨 macOS 與 Linux 的 Swift 發佈（Windows 需自行從原始碼編譯）。
- 更關鍵的是符號圖（symbol graph）需要 Swift 編譯器**型別檢查**原始碼，而本 App 依賴 `AVFoundation`／`UIKit`／`ScreenCaptureKit` 等 **Apple 專屬框架**，Windows 的 Swift 沒有這些 SDK；`.xcodeproj` 也只能在 macOS／Xcode 建置。

要在 Mac 或 CI（macOS runner）產生：

```
xcodebuild docbuild -scheme liveAPP -destination 'generic/platform=iOS' \
  -derivedDataPath build
# 產物：build/Build/Products/Debug-iphoneos/liveAPP.doccarchive
```

`.doccarchive` 是用 `swift-docc-render` 做前端渲染的靜態站，直接開 `index.html` 即可。可在 CI 加一個 job 產出並發佈，再由開發索引連過去。純 Swift、不依賴 Apple 框架的 package（例如可跨平台的部分）才可能在 Windows 用 `swift package generate-documentation` 產出。
