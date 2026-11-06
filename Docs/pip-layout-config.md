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
| `pipHideSystemControls` | 隱藏系統 PiP 的關閉／返回控制列（私有 `controlsStyle = 2`） |
| `pipCompactOverlay` | 控制列全隱藏時，把資訊列與聊天上移，回收上方保留帶 |
| `pipNoticeAvatar` | 次要提示顯示訊息頭貼（沒有頭貼時自動省略） |
| `pipMainTextColor` | 主要聊天文字顏色（`#RRGGBB`，預設 `#FFFFFF`） |
| `pipSecondaryTextColor` | 次要提示／次要聊天文字顏色（`#RRGGBB`，預設 `#DBDBDB`） |

這些 key 已經由 `LPConfig.shared` 與 `PIPService` 使用，因此第一版 PIP 排版頁只整理入口，不改資料模型。

## 實作入口

- `liveAPP/PIPLayoutSettingsView.swift`：獨立的 PiP 排版加工頁。
- `liveAPP/ContentView.swift`：主設定頁提供 `PIP排版加工設置` 入口。
- `liveAPP/PIPService.swift`：維持原本 `drawTimeOverlay()` 與聊天室排版邏輯，不讀取最終輸出 Overlay config。
- `liveAPP/Socket.swift`：直播狀態 fallback 使用 PiP 自訂文案；上游若傳回舊固定字串，會映射成目前自訂文字。

`PIPLayoutSettingsView` 頁面頂部提供 3:2 靜態預覽，對齊目前 PiP 啟動尺寸 `300x200`。預覽會即時反映聊天室字體、贊助覆蓋字體與間距，方便調整時快速查看視覺密度。

預覽的排版座標應貼近實際 PIP，且與 `PIPOverlayLayout` 共用同一組常數：

- 上方 `0–36` 是系統 PiP 關閉／返回按鈕的示意保留帶；實際繪製仍以 `controlSideInset` 為左右避讓距離。
- 計時器與直播狀態、觀眾數在**同一列**，`y = 36`；計時器靠左，不再單獨置中。系統控制列顯示時整列從 `x = 38` 開始、右界也留 38；控制列全隱藏時改從 `x = 12` 開始並用滿內容寬度。
- 現在時間 `y = 58`、次要提示 `y = 78`；兩者與聊天左緣一致。
- 次要提示維持單行，超過寬度時最多分成 4 頁、每頁 2.5 秒，右側以小圓點標示頁數；超過 4 頁的部分截斷加省略號。換頁沿用 1 FPS 時鐘，不拉高 PiP 渲染 FPS。
- 「顯示頭貼」開啟時，提示文字左側會排入 16pt 圓形頭貼（沒有頭貼則自動省略）；文字與頁碼寬度會重新分配。
- 主要聊天文字與次要提示／次要聊天顏色可在「PiP 排版設定」調整；次要預設由 `lightGray` 改為較亮的 `#DBDBDB`。狀態列、現在時間與贊助文字不受這兩個顏色影響。
- 系統按鈕只在 PiP 視窗被點擊時暫時出現，但無法偵測顯示時機，佈局一律以它們存在來保留空間。
- 聊天訊息安全頂距為 `max(100, height * 0.26)`；300x200 時是 `100`。
- 「隱藏控制列時將資訊列上移」開啟後（僅在控制列全隱藏時有效）：狀態列 `y = 20`、現在時間 `42`、提示 `62`、聊天頂距 `84`，把上方保留帶還給聊天，同時保留 20pt 上緣避開系統圓角。
- 贊助覆蓋顯示時，聊天訊息額外下移 `145`，與實際 `setAdOverlayOffset(145)` 保持一致。
- 預覽整幀由 `PIPPreviewFrameRenderer` 走正式繪製：聊天用 `PIPServiceMessages` 快照、時間用 `PIPTimeOverlayRenderer`、贊助用 `PIPAdOverlayRenderer`；SwiftUI 只負責縮放顯示與系統按鈕佔位，不再各畫一套。
- 預覽在窄畫面中必須使用實際可用寬度縮放，不應硬套 `300` 寬度，避免右側被裁切。
- 預覽會畫出兩顆系統控制鈕的佔位圈；控制列全隱藏時不畫，所見即所得。
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
