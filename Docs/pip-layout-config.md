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

預覽的排版座標應貼近實際 PIP，且與 `PIPOverlayLayout` 共用同一組常數：

- 上方 `0–56` 是系統 PiP 關閉／返回按鈕的保留帶；App 不在這條帶內畫時間或提示。
- 計時／直播狀態／觀眾數仍在帶內，但限制在左右各 `56` 的中央空檔，必要時先省略時鐘圖示、再省略觀眾數，不讓文字鑽到按鈕下方。
- 保留帶以下的列統一使用 `x = 12` 左緣：現在時間 `y = 60`、單行次要提示 `y = 84`；現在時間不再置中。
- 系統按鈕只在 PiP 視窗被點擊時暫時出現，但因為無法偵測顯示時機，佈局一律以它們存在來保留空間，避免跳動。
- 聊天訊息安全頂距為 `max(104, height * 0.26)`；300x200 時是 `104`。
- 贊助覆蓋顯示時，聊天訊息額外下移 `145`，與實際 `setAdOverlayOffset(145)` 保持一致。
- 預覽在窄畫面中必須使用實際可用寬度縮放，不應硬套 `300` 寬度，避免右側被裁切。
- 預覽會畫出兩顆系統控制鈕的佔位圈與一行次要提示，所見即所得。
- 直播時長、狀態與觀眾數徽章必須單行顯示；時間文字不可自動換行。
- 贊助顯示預覽只呈現上方資訊列與贊助覆蓋本身；聊天室訊息在實際畫面會被下推讓路，因此不硬塞進可視區。

狀態文字限制最多 12 個字，UI 提醒建議 2 到 6 個字。這是為了避免上方時間列、直播狀態與觀眾數徽章互相擠壓。

## 系統控制列

- 預設 `controlsStyle = 1`：保留關閉／返回按鈕，隱藏播放與跳轉控制。影片型 PiP 的控制列會自動淡出；sample buffer／live 視窗由系統決定，沒有公開的淡出開關。
- 「子母畫面」頁可開啟「隱藏關閉與返回按鈕」，改用 `controlsStyle = 2`（iOS 16+ 私有樣式），PiP 視窗內不再顯示任何系統按鈕。
- 關閉出口固定在 App：「子母畫面」頁的「停止 PiP」會呼叫 `stopPictureInPicture()`；即使控制列全隱藏也能真正結束，不會留下無法關閉的視窗。
- 這是非公開 API，側載可用；若系統改動可能失效，且無法在 PiP 視窗內關閉或返回 App。

## 原則

- 調整 PiP 不應影響 RTMP 最終輸出畫布。
- 調整最終輸出 Overlay 不應影響 PiP 子母窗口樣式。
- 後續若要加入 PiP 的位置拖曳或更完整預覽，應另建 PiP 專用 config，不要混用 `OverlaySceneConfig`。
