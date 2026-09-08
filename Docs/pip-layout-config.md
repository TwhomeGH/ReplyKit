# PIP 排版加工設計

本文整理 PiP 子母窗口排版設定。PiP 排版加工與最終推流畫布 Overlay 是兩套設定，不應共用同一份 scene config。

## 邊界

PiP 排版加工負責主 App 內的子母窗口畫面：

- 聊天室主訊息字體大小
- 次要訊息字體大小
- 贊助覆蓋字體與停留時間
- 訊息淡出速度與滾動時間

最終輸出 Overlay 負責 ReplayKit Extension 的推流畫布：

- 時間、Logo、浮水印、狀態文字
- 最終 `ODWidth x ODHeight` 16:9 畫布座標
- 直播輸出的畫面疊加

## 現有設定來源

PiP 排版頁使用現有 `@AppStorage` key：

| Key | 用途 |
| --- | --- |
| `PIPFontMain` | 主訊息字體與圖片基準大小 |
| `PIPFontSecond` | 次要訊息字體大小 |
| `PIPAdOverlayFont` | 贊助覆蓋內文字體 |
| `PIPAdOverlayUserFont` | 贊助者名稱字體 |
| `PIPAdOverlaySpacing` | 贊助者與內文間距 |
| `PIPAdOverlayDuration` | 贊助覆蓋停留秒數 |
| `fadeAlpha` | 訊息淡出速度 |
| `fadeTime` | 訊息淡出間隔 |
| `scrollTime` | 訊息滾動時間 |
| `PIPNowTimeLabelOverride` | 現在時間標籤自訂文字；空白時跟隨系統語言 |
| `PIPLiveLabelOverride` | 直播中狀態自訂文字；空白時跟隨系統語言 |
| `PIPEndedLabelOverride` | 直播已結束狀態自訂文字；空白時跟隨系統語言 |

這些 key 已經由 `LPConfig.shared` 與 `PIPService` 使用，因此第一版 PIP 排版頁只整理入口，不改資料模型。

## 實作入口

- `liveAPP/PIPLayoutSettingsView.swift`：獨立的 PiP 排版加工頁。
- `liveAPP/ContentView.swift`：主設定頁提供 `PIP排版加工設置` 入口。
- `liveAPP/PIPService.swift`：維持原本 `drawTimeOverlay()` 與聊天室排版邏輯，不讀取最終輸出 Overlay config。
- `liveAPP/Socket.swift`：直播狀態 fallback 使用 PiP 自訂文案；上游若傳回舊固定字串，會映射成目前自訂文字。

`PIPLayoutSettingsView` 頁面頂部提供 3:2 靜態預覽，對齊目前 PiP 啟動尺寸 `300x200`。預覽會即時反映聊天室字體、贊助覆蓋字體與間距，方便調整時快速查看視覺密度。

預覽的排版座標應貼近實際 PIP：

- 直播時長從 `x = 50, y = 20` 開始。
- 直播狀態與觀眾數徽章接在直播時長右側，使用同一排流式排列，避免長文字與時間列重疊。
- 現在時間列位於第二行，背景框從 `y = 48` 附近開始並置中。
- 聊天訊息安全頂距為 `max(88, height * 0.26)`；300x200 時是 `88`。
- 贊助覆蓋顯示時，聊天訊息額外下移 `145`，與實際 `setAdOverlayOffset(145)` 保持一致。

狀態文字限制最多 12 個字，UI 提醒建議 2 到 6 個字。這是為了避免上方時間列、直播狀態與觀眾數徽章互相擠壓。

## 原則

- 調整 PiP 不應影響 RTMP 最終輸出畫布。
- 調整最終輸出 Overlay 不應影響 PiP 子母窗口樣式。
- 後續若要加入 PiP 的位置拖曳或更完整預覽，應另建 PiP 專用 config，不要混用 `OverlaySceneConfig`。
