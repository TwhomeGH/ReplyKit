# 畫面加工 Overlay 配置設計

本文整理主 App 可視化配置與 ReplayKit Extension 讀取 Overlay 設定的設計。此功能是可選加工層；用戶不啟用時，既有輸出與原本 PiP overlay 行為應保持不變。

注意：本文件中的 Overlay 指「最終推流畫布加工」，不是 PiP 子母窗口排版。PiP 應使用獨立的 `PIPLayoutSettingsView` 與現有 `PIP*` 設定 key。

## 目標

- 在主 UI 提供獨立的「畫面加工設置」頁面。
- 讓用戶控制最終 16:9 畫布上的附加圖層，例如時間、浮水印、Logo、狀態文字。
- 第一版先支援時間圖層，包含位置與樣式控制。
- 以一份版本化 `Codable` 配置描述整個 overlay scene，避免設定散落成大量 `UserDefaults` key。
- 側載與直播啟動流程必須透過 socket 同步 Overlay config；App Group `UserDefaults` 作為同機快取與 fallback。

## 設計原則

Overlay 不屬於 GPU 處理尺寸設定。

GPU 頁面負責：

- ReplayKit 畫面旋轉
- GPU 中間處理尺寸 `dstW` / `dstH`
- 最終輸出畫布尺寸 `odstW` / `odstH`

Overlay 頁面負責：

- 哪些視覺圖層要顯示
- 圖層在 16:9 畫布上的位置
- 圖層樣式，例如字體、顏色、背景、透明度

因此 Overlay 應該是獨立設定頁，而不是塞進 GPU 旋轉處理頁。

## 配置模型

目前配置檔分別放在：

- `liveAPP/SharedOverlayConfig.swift`
- `ReplyKIT/SharedOverlayConfig.swift`

主 App 與 Extension 使用同一組 Codable schema：

```swift
struct OverlaySceneConfig: Codable, Equatable {
    var version: Int = 1
    var enabled: Bool = false
    var time: TimeOverlayConfig = TimeOverlayConfig()
}
```

時間圖層：

```swift
struct TimeOverlayConfig: Codable, Identifiable, Equatable {
    var enabled: Bool = true
    var anchor: OverlayAnchor = .topRight
    var marginX: Double = 24
    var marginY: Double = 20
    var offsetX: Double = 0
    var offsetY: Double = 0
    var fontSize: Double = 16
    var fontWeight: OverlayFontWeight = .medium
    var textColorHex: String = "#FFFFFF"
    var backgroundEnabled: Bool = true
    var backgroundColorHex: String = "#000000"
    var backgroundOpacity: Double = 0.45
    var cornerRadius: Double = 6
    var paddingX: Double = 8
    var paddingY: Double = 5
    var format: TimeOverlayFormat = .dateTime
}
```

位置使用 `anchor + margin + offset`，而不是直接保存絕對像素。這樣同一份配置可以套用到 `1280x720`、`1920x1080` 或其他 16:9 輸出尺寸。

## 資料流

主 App：

1. `OverlaySettingsView` 顯示 16:9 預覽畫布。
2. 用戶調整開關、位置與樣式。
3. `OverlaySettingsViewModel` 將 `OverlaySceneConfig` encode 成 JSON data。
4. `OverlayConfigStore.save()` 寫入 App Group `UserDefaults` 的 `OverlaySceneConfig` key。
5. 發送 Darwin notification：`OverlaySceneConfigChanged`。
6. `SocketServer.pushOverlayConfig()` 透過 socket 對已連線的 Extension 推送 `overlayConfig`。
7. 此設定不直接驅動 `PIPService`；最終由 ReplayKit Extension 的 video processor 套用到輸出畫布。

ReplayKit Extension：

1. 啟動推流時 `SocketClient.requestRTMPKEYAndLog()` 送出 batch，請求 `requestRTMP`、`logConfig`、`requestOverlayConfig`。
2. 主 App 回傳 `overlayConfig` payload，內含 `OverlaySceneConfig`。
3. Extension 收到 `overlayConfig` 後呼叫 `OutputOverlayMetalRenderer.apply(config:)`，立即更新 renderer cache，並同步寫回 App Group。
4. Batch 完成時會檢查 RTMP 與 Overlay config 是否都已收到；這能確保側載流程不是只靠 App Group fallback。
5. `Eventlisten.eventNames` 仍註冊 `OverlaySceneConfigChanged`，作為同機 App Group 更新 fallback。
6. `GPUVideoRotator.renderPlaneYUV()` 完成旋轉/縮放後，呼叫 `OutputOverlayMetalRenderer.applyIfNeeded()`。
7. Metal kernel `compositeOverlayBGRAToNV12` 將 overlay BGRA texture 混入最終 NV12 輸出畫布。

## 第一版實作範圍

已完成：

- 新增 Overlay Codable 配置。
- 新增主 App「畫面加工設置」入口。
- 新增 16:9 預覽畫布。
- 新增時間圖層位置與樣式控制。
- Extension 可收到配置變更通知並讀取配置。
- Socket batch 已包含 `requestOverlayConfig`，側載啟動時會同步 Overlay config。
- 主 App 儲存 Overlay 設定時會 push `overlayConfig` 給已連線 Extension。
- GPU rotator 已在旋轉後追加 Metal overlay pass，把時間圖層疊到最終 NV12 畫布。
- Overlay 時間貼圖只保留目前需要的一張 texture，避免每秒新增 texture 導致長時間推流記憶體與 PTS 壓力。
- CoreGraphics 產生的 overlay bitmap 與 Metal texture 座標系不同，合成 shader 會翻轉 overlay Y 軸再取樣。

刻意保留：

- 畫面加工預設關閉。
- 未啟用時維持原本 `drawTimeOverlay()` 行為。
- 保活模式仍使用原本中央提示樣式，不受一般時間圖層覆蓋。
- PiP 排版加工與最終輸出 Overlay 分離，避免調整輸出畫布時改壞 PiP 子母窗口樣式。

## 下一步

下一階段應該擴展 `OverlaySceneConfig` 的 layer 能力。

建議順序：

1. 把單一 `time` 欄位演進成 ordered `layers`。
2. 加入文字 layer、Logo/image layer、狀態 badge layer。
3. 讓主 App 預覽與 Extension renderer 共用同一套座標計算。
4. 為 overlay texture cache 加上上限與 memory warning 清理。

## 擴展方向

未來 layer schema 可以從單一 `time` 欄位演進成 ordered layers：

```swift
struct OverlaySceneConfig: Codable {
    var version: Int
    var enabled: Bool
    var layers: [OverlayLayerConfig]
}

enum OverlayLayerConfig: Codable {
    case time(TimeOverlayConfig)
    case text(TextOverlayConfig)
    case image(ImageOverlayConfig)
    case status(StatusOverlayConfig)
}
```

這樣可以支援：

- 多個文字圖層
- Logo / 浮水印
- 直播狀態 badge
- 觀眾數與 bitrate
- 聊天室區塊位置化

## 注意事項

- Extension 不能依賴主 App 記憶體狀態；側載流程以 socket 同步為主，App Group `UserDefaults` 只作快取與 fallback。
- Codable schema 要保留 `version`，未來增加欄位時需提供 fallback 預設值。
- 位置計算應以最終畫布尺寸為準，也就是 OD 尺寸，不應使用 GPU 中間處理尺寸 AD。
- Overlay 若進入推流畫布，必須確認是否會影響 encoder timing、pixel buffer reuse 與記憶體壓力。
- 若直播中看到 PTS 抖動，先看 `[OverlayMetal]` log 是否大量重建 pipeline 或 texture；正常情況下時間文字每秒更新一次，但 overlay composite 會每幀執行。
