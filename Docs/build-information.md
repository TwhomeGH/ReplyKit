# 關於與建置資訊

## 使用方式

在設定頁開啟「關於與建置資訊」。頁面顯示 App 與 HaishinKit 的來源修訂、建置時間與來源，辨識依據不依賴 MARKETING_VERSION 或 CURRENT_PROJECT_VERSION。

commit 在畫面上顯示前 12 碼；「複製完整版本資訊」與「分享版本資訊」保留完整 commit。回報問題時可以貼上這份文字。主 App 每次初始化也會將同一份資料以 `[BuildInfo]` 前綴寫入 Documents/log.txt。

## 欄位與判讀

| 欄位 | 來源與意義 |
| --- | --- |
| App commit | 建置當下原始碼 repository 的完整 HEAD，使用 checkout 實際值，不使用可能屬於觸發事件的 GITHUB_SHA |
| App 原始碼狀態 | Git status，包含已追蹤及未忽略的未追蹤修改；有修改時不能只用 commit 重現該產物 |
| HaishinKit 鎖定 commit | 專案 workspace 的 Package.resolved 所鎖定的完整 revision |
| HaishinKit checkout commit | 找到套件 checkout 時讀取其實際 HEAD；未取得顯示未知 |
| HaishinKit 版本標籤 | 套件鎖定資料的 version；使用 branch／revision 而未記錄 version 時顯示未知，不把分支名稱當版本 |
| HaishinKit 原始碼狀態 | checkout 是否有未提交修改；即使 commit 相同，修改中的套件也不是原始 commit 的完整重現 |
| 套件核對結果 | 相符、不同、僅鎖定值未核對、缺少資訊；commit 相符但有修改會額外說明 |
| 產物識別碼 | 每次產生建置快照時建立的 UUID，區分同一 commit 的不同建置，不是版本號或二進位雜湊 |
| 建置時間 | UTC 時間，固定於產物，不是 App 啟動時間 |
| 建置來源 | GitHub Actions 或本機 |
| 組態、平台、Xcode、SDK | Xcode build environment；Xcode 使用 XCODE_VERSION_ACTUAL 的數字代碼 |
| CI 執行編號／重跑次數 | GITHUB_RUN_ID 與 GITHUB_RUN_ATTEMPT；本機沒有時顯示未知 |

## 建置流程

主 App 的 `Generate Build Information` Run Script 階段執行 `Scripts/build_info.py`，直接寫入 `TARGET_BUILD_DIR/UNLOCALIZED_RESOURCES_FOLDER_PATH/BuildInfo.json`，在簽署前成為 App bundle 的一部分。每次 build／archive 都重新產生，不把已生成檔案放進原始碼 repository。

- `BuildInformation.current` 只讀 bundle 中的快照；關於頁、複製／分享及啟動日誌共用。
- 資訊缺失、檔案解碼失敗或格式版本不支援時顯示未知，不退回專案版本號，也不從網路推測。
- 套件鎖定檔固定為 `liveAPP.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`，不誤用根目錄另一份 Package.resolved。
- CI 使用 `BUILD_INFO_PACKAGES_DIR` 與 `-clonedSourcePackagesDirPath` 指向相同 checkout 目錄，依原本鎖定套件的方式建置。舊的 sed 修改 HaishinKit Constants.swift 流程已移除。
- 本機未指定目錄時，沿 BUILD_DIR 的父目錄查找 Xcode SourcePackages/checkouts。找不到就只顯示鎖定 revision，不宣稱已核對。
- 若有自訂套件目錄，可在 Xcode 建置設定提供 BUILD_INFO_PACKAGES_DIR。手動 local package override／非標準套件配置不在自動識別範圍；核對結果只代表找到的 checkout 與鎖定檔比較，不能作為完整依賴來源證明。
- 主 App target 的 Debug／Release 關閉 User Script Sandboxing，供此階段讀取 Git metadata、worktree metadata 及 Xcode 外部套件 checkout；其他 target 保留原設定。腳本只執行唯讀 Git 命令及寫入指定產物資訊檔，不修改套件。

建置機需有 Python 3 與 Git。腳本找不到來源資訊時仍可寫入未知；若腳本無法執行或資訊檔無法寫入，建置階段應失敗，避免產出沿用舊快照的包。

## 測試與限制

- 產生器測試涵蓋缺少 Git、專案鎖定檔優先、checkout 相符但有修改、revision 不符、真實 Git dirty 偵測，以及損壞鎖定檔。
- Swift 模型測試涵蓋缺少或不支援的資訊、完整 commit 保留、修改狀態與 mismatch 顯示。
- CI 的 unit-tests workflow 會先執行 Python 產生器測試，再執行包含 BuildInformationTests 的 liveAPPTests。
- Windows 可驗證產生器、JSON 讀取及 Swift 核心邏輯；App bundle 最終封裝、Xcode 建置階段、iOS 頁面與剪貼簿需由 CI／實機驗收，不能以語法檢查代替。
