# Socket 模組與維護入口

| 檔案（liveAPP/ 下） | 責任 |
| --- | --- |
| Socket.swift | listener／端口切換、連線、換行 JSON 收送及訊息分派 |
| Networking/NWListenerState_Log.swift | listener 狀態轉日誌文字；不以字串控制連線狀態 |
| Networking/SocketServer_JSONValue.swift | 保留巢狀型別名稱的 Codable／Sendable JSON 模型與轉換 |
| Audio/AudioLogFormatting.swift | 線性振幅倍率轉百分比與相對 dB；純函數 |

## JSON 值的用途

foundationValue 保留 JSON null 為 NSNull，可供 JSONSerialization 使用。propertyListValue 專供 UserDefaults，任何層級的 null 或非有限浮點值都使整筆回傳 nil；不移除陣列元素、不偷偷刪掉物件欄位。頂層 null 維持不更新設定，沒有定義為刪除偏好。

JSONValue 解碼明確處理 null；無法解碼的值丟出錯誤，不偽裝成 null。它是值型別，不需要每個 case 加鎖；共享 encoder／decoder 與服務可變狀態的執行緒責任仍屬 SocketServer。

## 註釋重點

收送資料以換行分隔，不把 TCP 回呼當作訊息邊界。receiveOffsets 記錄已消耗區段；再次 receive 排入佇列避免同步遞迴。傳送完成只代表本機 Network 回呼完成，不代表對端完成處理。

SocketServer 使用 @unchecked Sendable，不能據此宣稱全部狀態均隔離。本批只拆出純函數與 JSON 模型，沒有把服務改為 actor，也恢復流程另依下節統一管理。完整佇列隔離與待送量限制另列 TODO。

音量文字是線性倍率與相對振幅 dB，不是校準聲壓或實測 dBFS；非有限值明示 invalid。格式固定使用 POSIX locale，避免小數符號隨裝置地區改變。

## Listener 恢復與通知生命週期

- `SocketRecoveryPolicy` 是純決策模型。`requestRecovery` 是服務 queue 上的唯一被動恢復入口。
- `start`、`resume`、開播準備及套用端口屬明確啟用；`ensureRunning`、Darwin 提示與 listener 錯誤不推翻 stop。
- ready／setup／waiting 保留；不存在／failed／cancelled 才建立 listener。重建 listener 不取消其他仍健康的連線。
- 恢復要求合併為一個 UUID 排程；單調時鐘限制建立嘗試至少間隔三秒，冷卻期改為延後而非丟棄。
- 端口切換期間延後恢復；候選失敗後重查原服務。EADDRINUSE 暫停自動重試，由使用者重試或改端口解除。
- `liveAPP.SocketRestart` 保留協定名稱，但只是提示。notify_register_dispatch 將弱參考 block 送到服务 queue；不再用裸 self 指標，析構以 notify_cancel 解除註冊。
- stop 清除排程與連線，並更新生命週期世代，使舊等待 ready 工作失效。deinit 同步取消 token、listener、連線與 timer，不排入依賴 self 的清理工作。
- suspend 只關閉客戶端及保活 timer，listener 仍可接受新連線；它不等於 stop。
- UI 的 listenerStatus 才是監聽摘要；isStopping 僅表示停用意圖，不能推導 ready。

Darwin 通知不含已驗證的呼叫者，也不保證喚醒被系統暫停的 App，不應作為重建全部連線的命令。Apple API：[notify_register_dispatch](https://developer.apple.com/documentation/darwinnotify/notify_register_dispatch(_:_:_:_:))。

## 驗證界線

恢復純決策已在 Windows 編譯並實際執行，另加入 Swift Testing 回歸案例。Network.framework 與 Darwin 通知的真實交錯仍需 Apple CI／實機驗證；不能將語法解析當成 iOS 整合測試通過。
