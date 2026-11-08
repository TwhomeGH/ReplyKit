# 音量控制與監測

- 輸出增益顯示 dB，0 值顯示靜音；滑桿 0–100% 是控制位置，保留既有對數映射，不代表線性振幅百分比。
- ScreenCaptureKit 的 App／Mic 來源 RMS 在混音前量測，不隨增益變化。
- 調整後 RMS 是來源振幅乘上 Mixer 已接受增益的估算，沒有分軌輸出實測保證；處理器、混音相位與不同取樣時間可能造成差異。
- 混音輸出 RMS 為混音後實測；不代表伺服器收到或遠端播放驗證。
- 音量表固定 −60 至 0 dBFS，數字保留實際值，超出範圍只截斷長條；不能用 RMS 判斷瞬間峰值削波。
- Mixer 套用回報以 session 隔離；停止清空，沒有麥克風音軌時不宣稱已套用。

## 實機驗收（待完成）

1. 只輸入 App 聲音，將 Mic 靜音；App 增益切換 0 dB、−20 dB、靜音，檢查混音實測及遠端聲音／可控錄製音軌。
2. App 靜音，只輸入麥克風，重複上一步，確認兩個控制各自生效。
3. 停止、重開擷取，確認不沿用上一場數值；未收到資料及過期時不顯示有效估算。
4. 系統直接錄製不經此 Mixer，不應用此頁的套用狀態推斷其音量控制。

## ReplayKit 設定同步

音量通知只標記需更新，不攜帶值。新版擴展由單一工作依序讀取兩軌快照、更新同一份 Mixer 設定，再等待音訊處理 actor 接受估算增益。快速通知合併處理，不建立多個互相覆蓋 Mixer 的工作。

- Socket／側載：沿用 `UPSet`，key 為 `audioVolumeSnapshot`，ValueType 為 `String`。value 是 schema=2、app、mic、micGain 的 JSON 字串。
- 共享容器路徑：讀取兩軌偏好，再一次套用；UserDefaults 並非跨程序交易，五秒補查會收斂到最新值。
- 通知之外每五秒補查，連線恢復後重新取得最新值；不讀取失敗就回退滿音量。
- 音量 0 表示靜音。讀取 RTMP 配置不再把它改成 1，也不寫回偏好。
- 新版擴展搭配舊版主 App 若拿不到快照，保留初始／現有音量並回報同步失敗；即時音量控制需主 App 與擴展一起更新。

回覆 `audioVolumeApplied` 包含 schema、session、revision、reportedAt、status，以及成功套用後的 app／mic。revision 是該擴展 session 的套用序號；串行工作確保舊請求不會在新請求之後覆寫。status 包含 applied、syncFailed、tracksUnavailable、stopped。主 App 只把與目前需求相同且十二秒內的成功回覆標為已套用。此回覆不代表遠端播放驗證。

舊版擴展仍可回報既有音量；缺少套用回覆時顯示未提供，不以來源 RMS 推斷設定已生效。ReplayKit 與 ScreenCaptureKit 的 RMS 回報契約尚待統一，本次不更動降噪與回音消除演算法。

### 控制流程驗收

1. App／Mic 設為靜音後開播、重新請求 RTMP 配置，確認仍為 0。
2. 快速交錯調整兩軌，確認最終套用值與滑桿一致，另一軌不被還原。
3. 中斷控制 Socket 後調整，再恢復連線，確認補查及套用回覆恢復；失敗期間保留原值。
4. 停止時有進行中的設定請求，確認停止後不再回報成功；新場次使用不同 session。

## 共用音訊控制模組

- `SharedCapture/AudioControlSettings.swift`：主 App 與擴展共用設定快照、合法範圍及協議版本。一般音量 0…1，Mic 額外增益 1…30 倍。
- `liveAPP/Audio/AudioControlCoordinator.swift`：音量頁通知的統一入口，目前偏好仍由 AppStorage 綁定保存。
- `ReplyKIT/ReplayVolumeSynchronizer.swift`：跨程序適配器，成對更新 Mixer 後等待處理 actor 更新 Mic 增益，再回覆成功。
- `liveAPP/Audio/LiveVolumeModel.swift`：音量及套用回報狀態，與 SwiftUI 排版分離。
- ScreenCaptureKit 使用同一設定模型同步一般音量；尚不支援額外 Mic 增益，畫面停用並說明。

Mic 額外增益在原音路徑對 PCM 套用，在處理路徑更新 AudioEngine 的後段增益；本次修正既有 engine 沒收到更新的缺口，不改變降噪／AGC／回音消除演算法。App 額外增益固定為 1 倍，舊偏好不刪除但不再套用，畫面提供退場說明。

待實機驗證：原音及處理模式分別調整 Mic 1／2 倍，確認套用回覆與聲音改變；確認 ScreenCaptureKit 不可操作額外增益；確認舊 App 增益大於 1 時，更新後維持原始 App 參考訊號。
