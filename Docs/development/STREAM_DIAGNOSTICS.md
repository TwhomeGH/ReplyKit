# 設備資訊：串流格式與 RTMP 傳輸

## 入口與更新

設備資訊頁的「串流格式與 RTMP 傳輸」提供 ReplayKit、ScreenCaptureKit 各自的展開區塊。每五秒取樣，只保存每個來源最新一筆；超過十五秒標為歷史資料。ReplayKit 由擴展經 Socket 傳入，ScreenCaptureKit 直接更新同一模型。來源 session UUID 與 socket generation 分別表示探針生命週期與連線計數世代。

## 已接入

- Mixer 實測：影像寬高、pixel FourCC、已知 NV12 色彩範圍、色彩 primaries／transfer／matrix 附件；PCM 格式、Hz、聲道、位深與交錯方式。只保存文字，每秒最多解析一次，不保留媒體 buffer。
- 編碼設定：目前 RTMPStream 的 profile／尺寸／影片碼率與音訊 codec／碼率，包含設定更新後的值；不是壓縮結果的格式證明。
- 影片事件：encoderDelivered 與 videoQueued 累計；缺 key 顯示未提供，不把各階段相加。
- Socket：generation、待完成／本機完成 bytes、失敗批次完整 bytes、成功／失敗批次、最近完成回呼耗時。來源是 transportDiagnostics()，不是日誌解析。

## 尚未提供

實際壓縮影片／音訊 format description、編碼後色彩資訊、RTMP chunk 數、音訊訊息數及 ACK。目前 StreamOutput 回呼主要是編碼前樣本，metadata 部分欄位取自設定，兩者都不能冒充實際編碼結果。需要底層新增只讀結構化接口並更新 App 鎖定版本後接入。

本機完成僅表示 Network.framework 完成回呼無錯誤，不證明伺服器收到或解碼。失敗批次可能部分傳出。socket 批次不等於 RTMP chunk，影片入列事件也不等於網路成功。

## 傳輸協定與相容

SharedCapture/StreamDiagnostics.swift 定義 schemaVersion=1、type=streamDiagnostics 的 Codable 快照；時間使用 JSONEncoder 預設 Date 編码。缺少的可選值保留 nil。未知 schema／來源不更新畫面，較舊取樣不覆蓋最新值。舊擴展未送出時顯示尚未收到。

## 驗證

新增 StreamDiagnosticsTests 驗證 Codable 的 nil／零區別與世代保留、舊快照與未知 schema 隔離。Windows 僅做 Swift 語法及靜態檢查；完整 XCTest/Swift Testing、iOS 編譯與雙來源實機斷線驗收由 CI／裝置執行。
