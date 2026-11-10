# App 圖示診斷與包體占用

## 已發布產物比較

直接讀取 GitHub Release 的原始 IPA ZIP，未安裝或執行內容。

- [17.2.8](https://github.com/TwhomeGH/ReplyKit/releases/tag/17.2.8)：5,148,762 bytes，約 4.91 MiB。
- [17.2.9](https://github.com/TwhomeGH/ReplyKit/releases/tag/17.2.9)：7,711,578 bytes，約 7.35 MiB。
- 差額 2,562,816 bytes（約 2.44 MiB）。以下以 ZIP entry 壓縮大小統計，不含 ZIP 標頭；不是 iOS 安裝後實際占用或 Documents 使用量。

| 分類 | 17.2.8 MiB | 17.2.9 MiB | 增量 MiB |
| ------ | ------ | ------ | ------ |
| 主 App 執行檔（含靜態連結程式碼） | 2.196 | 2.249 | +0.053 |
| 主 App 資源目錄 Assets.car（無法僅按檔案拆出個別圖示） | 1.556 | 3.947 | +2.391 |
| 擴展/ReplyKIT.appex | 1.019 | 1.019 | -0.000 |
| 疑似開發用檔案 | 0.033 | 0.033 | +0.000 |
| 其他資源／中繼資料／簽章 | 0.032 | 0.032 | +0.001 |
| 主 App 獨立 PNG／圖示 | 0.027 | 0.027 | +0.000 |
| 擴展/liveAPPWidget.appex | 0.025 | 0.025 | +0.000 |
| 擴展/ReplyKITNotification.appex | 0.009 | 0.009 | +0.000 |
| 擴展/ReplyKITSetupUI.appex | 0.003 | 0.003 | +0.000 |

Assets.car 增加 2,506,743 bytes，占整個 IPA 增量約 97.8%；主程式增加 55,291 bytes。
這證明主要增量位於編譯資源目錄，但不能只憑檔案大小將其中每一 byte 都歸到某一張圖示。
圖示與預覽會經過 asset catalog 編譯，原始 PNG 大小不等於 IPA 增量。
原本已有主程式、ReplyKIT 廣播擴展、Widget、通知／設定擴展、預設圖示與資源、Metal 函式庫及本地化字串。
靜態連結的套件程式碼屬於執行檔的一部分，不能以此清單再拆算 HaishinKit 的精確占比。

原產物也確實包含修改腳本與 .bak／.edit 檔，壓縮後合計約 34 KB。
本次從 App target 排除 18 個開發用檔案（含 `AudioProcess.swift.new`、`.last_build`），保留專案原檔；此項不是主要體積來源。
Artwork 原稿目錄不在原始 IPA 中。

## 圖示切換

17.2.9 原始產物的 CFBundleIcons 與 CFBundleIcons~ipad 都有 PersonalIcon，
但替換圖示項目只有 CFBundleIconName，沒有 CFBundleIconFiles，也沒有替換圖示的獨立 PNG。
因此已排除「CI 原始 IPA 完全漏掉 iPad 宣告」；尚不能證明是側載或重簽工具造成。

本次 PersonalIcon 改用明確 iPhone 60pt（2x／3x）、iPad 76pt（1x／2x）、83.5pt（2x）及 1024px marketing 資源。
Xcode 會把這些 renditions 編進 Assets.car，Info.plist 仍使用 `CFBundleIconName`，通常不會產生替換圖示的獨立 PNG；
因此 17.2.9 的宣告形式本身不是缺漏。CI 檢查接受 `CFBundleIconName` + Assets.car，或 `CFBundleIconFiles` + 對應 PNG。
是否解決實機 supportsAlternateIcons=false 仍需新版驗證；不手動繞過系統回報。

App 圖示頁提供診斷展開與複製：系統支援狀態、目前圖示、iPhone／iPad 宣告名稱與 PNG 檔案名稱。
若原始 CI 通過但實機宣告不同，需比對重新簽署後 IPA；若相同仍不支援，再調查系統與資源相容性。

## CI 與離線工具

Scripts/inspect_app_bundle.py 可讀取 .app 或 IPA，不修改內容。
CI 封存後驗證兩個裝置分支的 PersonalIcon 宣告；接受 `CFBundleIconName` + Assets.car，或 `CFBundleIconFiles` + 對應獨立 PNG。缺少 Assets.car／PNG 時失敗；報告仍上傳。
報告另列「套件內容」與「預期排除清單」：任何 `.py`／`.bak`／`.edit`／`.swift`／`.new`／dotfile 被包進去，或 `Scripts/package_exclusions.txt` 內應排除的檔案仍存在，CI 都會失敗並列出路徑。
打包後再次輸出最終 IPA 的壓縮大小、檔案加總、分類與最大 30 個檔案，並重跑同一份排除清單。
報告附於 GitHub Actions 摘要及 app-bundle-report／ipa-size-report artifact。

`.app` 目錄沒有 IPA ZIP，因此報告只列未壓縮檔案大小，不列逐檔 ZIP 壓縮量；`IPA ZIP 大小` 只在實際 IPA 輸入時提供，且代表整包下載／儲存大小。逐檔 ZIP entry 壓縮大小不含 ZIP 標頭，不能加總後宣稱等於整包 IPA 大小。

```sh
python3 Scripts/inspect_app_bundle.py path/to/app.ipa --output report.md \
  --expect-excluded Scripts/package_exclusions.txt
python3 -m unittest discover -s Scripts -p test_inspect_app_bundle.py
```

不會將 Assets.car 全部算成單一圖示；不含使用者文件、快取，也不等同系統設定頁的空間計算。
若要減少圖示體積，需比較新版產物再決定圖片簡化或改圖，不先犧牲原稿畫質。

目前 Assets.car 的 asset 名稱只有 `AppIcon`、`PersonalIcon`、`PersonalIconPreview`、`DefaultIconPreview` 與 `AppIcon.png`／`PersonalIcon-*.png` 等圖示 renditions；4.9 MB 幾乎全部是圖示與預覽，不是其他圖片或一般資源。來源 asset catalog 約 3.1 MB，編譯後變大是因為 iOS 圖示的 idiom／appearance renditions 與 asset catalog 編碼，不能再用來回推某一張 PNG 的增量。

KSign 相容層只應複製 `CFBundleIconFiles` 實際引用的尺寸（PersonalIcon-76／120／152／167／180）；1024 marketing `PersonalIcon.png` 已由 Assets.car 提供，且未被列在 `CFBundleIconFiles`，複製到 App 根目錄只會增加約 1.79 MB 的重複圖示資料。
