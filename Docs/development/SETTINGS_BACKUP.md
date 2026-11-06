# 設定備份與側載到期資料保留

## 使用入口

工具 → 備份與還原。設定變更後約兩秒自動檢查並備份，不需要停留在備份頁。
內容未變不重寫；進背景時補存。系統凍結或簽署到期後不能再執行備份，請查看最近成功時間。

## 刪除 App 前先搬走

若 App 掉簽無法開啟，使用「檔案 → 我的 iPhone／iPad → 松鼠推流」，將下列資料複製至 iCloud Drive、其他 App 或電腦。
確認副本可讀後再刪除 App；存放在 App 文件裡的備份不會在刪除 App 後保留。

| 目錄 | 內容 |
| ------ | ------ |
| ConfigBackups | JSON 設定備份；自動備份不含連線網址及金鑰 |
| CompressedVideos | 手動壓縮完成的影片 |
| ScreenRecordings | 本地錄影、分段及 JSON 索引；請整個資料夾一起保存 |

舊版錄影位於 Library/Application Support/ScreenRecordings，無法直接由「檔案」取得。
此版首次啟動即搬移至 Documents/ScreenRecordings；若新庫已有內容，舊庫放入 PreviousLibrary 子目錄。
不覆蓋既有目錄。搬移失敗會提示，App 仍嘗試讀取舊庫以供分享；必須先成功啟動新版才能執行這次搬移。
新版尚未啟動前就已掉簽的舊錄影，不能宣稱已在共享文件裡。

## 保存內容與保留數量

SettingsBackupRegistry 集中列出允許的鍵、儲存區和型別，包括已保存的擷取／編碼、錄影、音訊、TTS 過濾、PiP、GPU 畫布、時間疊加、Live Activity、Socket 連接埠及日誌偏好。
沒有保存的鍵不捏造預設值；目前頁面、正在直播、即時診斷、媒體檔、系統權限、App 圖示與裝置相關的擴展 Bundle ID 不備份。
不是整份 UserDefaults dump，也不是整個 App 容器備份。

| 檔名 | 用途 |
| ------ | ------ |
| settings-latest.json | 最近成功的自動備份 |
| settings-previous.json | 上一次自動備份 |
| settings-before-restore.json | 確認還原前的設定 |
| settings-export.json | 最近手動匯出的一般設定 |
| settings-export-sensitive.json | 最近手動匯出的敏感設定 |

最多使用五個固定檔名，每份限制 2 MB；不刪除自行另存的其他檔案。
重複匯出更新同名檔，需要長期保留的版本請另存外部。
敏感資料包括 rtmpURL、rtmpKey、logURL、streamConfigs 與 activeStreamConfigID。
只有手動勾選包含敏感設定才匯出；這是明文檔案，關閉選項不會刪除先前的敏感備份。
還原含敏感設定的檔案時，還原前快照亦會包含目前的敏感設定。

## 還原流程

1. 從 JSON 選擇匯入副本，或在已保存清單點預覽還原。
2. 檢查備份時間、項目數、敏感資料標記與欄位名稱。
3. 停止擷取、直播、壓縮與 PiP，再確認排定還原。
4. 完整關閉 App 並重新開啟；只回到前景不算重啟。重新開啟前不要修改設定。
5. 回到備份頁查看還原結果。若尚未重新啟動，可以取消待還原設定。

還原採合併：備份內的鍵覆寫，缺少的鍵保留原值，不會替換整個偏好 domain。
版本、大小、白名單、型別及數值範圍不合法時拒絕整份匯入。
下一次共享偏好初始化前套用，避免已建立的 TTS、PiP 或 Socket 物件只讀到一部分新設定。
有 App Group 時，排定及實際套用都檢查擷取排他鎖；無 App Group 時無法保證跨程序互斥，請自行先停止廣播擴展。
失敗保留 PendingSettingsRestore.json 供下次啟動重試，也可在備份頁取消。

## API 與維護

- SettingsBackupRegistry.capture：取得白名單設定快照，預設呼叫端不包含敏感資料。
- SettingsBackupDocument.encoded／decode：JSON 版本 1 的輸出與有界驗證。
- SettingsBackupStorage.save：原子寫入及前一份保留。
- SettingsBackupManager：全 App 單例，觀察設定變更、提供分享檔及排定還原。
- RecordingStorageMigration.migrate：搬移目錄並回傳可讀路徑與警告，不覆蓋新庫。

新增設定時需同步 Registry；檔案以 shared／standard 區分儲存來源，複合 Data 設定轉成可讀 JSON。
錯誤日誌只記錄錯誤領域與代碼，避免把設定值或金鑰寫進 log.txt。

## 驗收

- 單元測試涵蓋敏感與執行狀態排除、JSON 往返、錯誤匯入不部分套用、版本拒絕、前一份保留及錄影目錄衝突。
- Windows 僅完成 Swift 語法檢查；完整建置與測試需 Xcode／CI。
- 實機確認設定變更後備份時間更新、背景前補存、匯入重啟後 TTS／PiP／Socket 一致，以及含敏感資料的明確提示。
- 實機確認「檔案」能取出三個目錄，舊錄影仍可播放／分享，分段與合併操作正確。
