# 畫面加工 Overlay 配置設計

本文整理主 App 可視化配置與 ReplayKit Extension 讀取 Overlay 設定的設計。此功能是可選加工層；用戶不啟用時，既有輸出與原本 PiP overlay 行為應保持不變。

## 目標

- 在主 UI 提供獨立的「畫面加工設置」頁面。
- 讓用戶控制最終 16:9 畫布上的附加圖層，例如時間、浮水印、Logo、狀態文字。
- 第一版先支援時間圖層，包含位置與樣式控制。
- 以一份版本化 `Codable` 配置描述整個 overlay scene，避免設定散落成大量 `UserDefaults` key。
- 主 App 寫入 App Group `UserDefaults`，ReplayKit Extension 透過 Darwin notification reload。

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
6. 呼叫 `PIPService.shared.markOverlayDirty()`，讓 PiP 預覽重新繪製。

ReplayKit Extension：

1. `Eventlisten.eventNames` 註冊 `OverlaySceneConfigChanged`。
2. `SampleHandler.handleEvent()` 收到事件。
3. `OverlayConfigStore.load()` 從 App Group `UserDefaults` 讀取 Codable data。
4. 目前先記錄配置更新 log，後續接入最終 video processor。

## 第一版實作範圍

已完成：

- 新增 Overlay Codable 配置。
- 新增主 App「畫面加工設置」入口。
- 新增 16:9 預覽畫布。
- 新增時間圖層位置與樣式控制。
- PiP 時間 overlay 可讀取新配置。
- Extension 可收到配置變更通知並讀取配置。

刻意保留：

- 畫面加工預設關閉。
- 未啟用時維持原本 `drawTimeOverlay()` 行為。
- 保活模式仍使用原本中央提示樣式，不受一般時間圖層覆蓋。

## 下一步

下一階段應該把 `OverlaySceneConfig` 接進 ReplyKIT 的最終影片輸出路徑。

建議順序：

1. 在 Extension 端新增持有目前 overlay config 的狀態，例如 `currentOverlayConfig`。
2. 收到 `OverlaySceneConfigChanged` 時 reload 並更新該狀態。
3. 在 `VideoProcess` 或 rotator 輸出最終 `ODWidth x ODHeight` 畫布後，套用 overlay。
4. 先支援 CPU/CoreGraphics 疊時間，驗證尺寸與座標正確。
5. 再視效能需求轉成 Metal overlay pass。

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

- Extension 不能依賴主 App 記憶體狀態，必須從 App Group `UserDefaults` 或 socket 同步讀取。
- Codable schema 要保留 `version`，未來增加欄位時需提供 fallback 預設值。
- 位置計算應以最終畫布尺寸為準，也就是 OD 尺寸，不應使用 GPU 中間處理尺寸 AD。
- Overlay 若進入推流畫布，必須確認是否會影響 encoder timing、pixel buffer reuse 與記憶體壓力。
