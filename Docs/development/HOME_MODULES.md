# 主頁模組與維護入口

## 第一批拆分

| 檔案（liveAPP/ 下） | 責任 |
| --- | --- |
| ContentView.swift | 頂層分頁、環境注入及原本的頁面／前背景通知 |
| Navigation/AppPage.swift | 分頁識別與 PageState |
| Home/HomeView.swift | homeView 的狀態、Binding、權限提示及響應式排版 |
| Home/HomeView+Cards.swift | 擷取、串流、編碼、ReplayKit 操作及權限卡片組合 |
| Home/StreamConfigurationForm.swift | RTMP 配置表單與私有 StreamKeyField |
| Home/BroadcastButton.swift | 系統廣播選擇器與既有 Coordinator |
| Home/BitrateManager.swift | 碼率偏好保存與擴展通知 |
| Home/VideoProfiles.swift | H.264／HEVC 設定選項 |
| Audio/LiveVolumeView.swift | 原音量模型、頁面及私有格式／滑桿輔助函數 |
| Settings/LogSettingsView.swift | 原日誌與顯示設定頁，內部分區尚未重構 |
| Settings/GPUOutputConfig.swift | 原 GPU 配置與方向型別 |
| Logs/LogView.swift | 日誌來源模式與 FileLogView 入口 |
| Components/AnimatedButton.swift | 共用按鈕動畫 |
| Support/AppPreferences.swift | 原本共用偏好、logger 與 Darwin 通知中心 |

## 狀態與生命週期

本批保留 homeView、FormView 等既有型別名稱與呼叫點。HomeView 的 property wrapper 沒搬入子 View；卡片 extension 只組合畫面。只有跨檔案引用所需的 private 成員改為模組內可見，不新增 public API。

StateObject、共享 Coordinator、系統廣播按鈕、金鑰揭露狀態、onAppear/onDisappear/task 及分頁通知維持原位置與內容。沒有新增 Socket、Timer、監聽器或改動推流流程。

新增檔案位於 Xcode 已同步的 liveAPP 根群組下，無須逐一手改專案檔。後續新增卡片時先確認狀態擁有者；不要在卡片建立第二份共享服務。

## 驗證與後續

- 已比對拆分前後非註釋程式內容，除了必要 private 可見性調整均相同。
- Windows Swift 語法解析與差異檢查通過；不等於 Apple SDK 型別檢查通過。
- 待 CI／實機確認分頁、RTMP 配置保存、金鑰隱藏、寬窄版面、來源切換、開播／停止、音量及前背景行為。
- 第二批再拆設定頁內部區塊與音量頁，狀態／服務架構調整另案處理。

## 提交前設計修正

完成純搬移比對後，另修正下列原有行為，不能再將整批稱為只搬檔：

- RTMP 表單改用 StreamConfigurationDraft；選取與輸入只更新草稿，取消／滑掉不保存。「儲存並套用」驗證名稱、RTMP／RTMPS 網址及非空金鑰後，透過 saveAndActivate 保存。刪除仍為明確操作，不停止串流。
- 主頁移除 init 中的示例回填；空值保持空白，示例由表單手動選擇。
- 碼率由倍率單一推導，1–20 Mbps、100 kbps 步進；非正值後備為 6 Mbps，初始化不寫偏好，編輯完成才保存。
- 廣播擴展成功解析由 Coordinator 快取；失敗每五秒最多重試一次，避免 updateUIView 重複掃描和日誌。
- 新增 HomeConfigurationTests，使用獨立 UserDefaults suite 驗證空白草稿不覆寫、套用新增配置、ID 保留及碼率邊界。Apple 測試尚待 CI 執行。
