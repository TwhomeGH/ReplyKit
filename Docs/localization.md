# 本地化與翻譯流程

ReplyKit 的主 app 介面逐步改用 Apple String Catalog。現階段先把新加入的「PIP 排版加工」與「輸出畫面加工」頁面接進本地化，後續再分批把舊頁面中文字串搬進同一套流程。

## 本地化文件

- 主 app UI 字串集中放在 `liveAPP/Localizable.xcstrings`。
- 專案 source language 是 `zh-Hant`，目前目標語系是 `en` 與 `ja`。
- `liveAPP.xcodeproj/project.pbxproj` 的 `knownRegions` 已加入 `ja`，讓 Xcode 知道日文是支援語系。
- 如果後續要翻譯 app 名稱、權限文案或 Info.plist 內顯示文字，再新增 `InfoPlist.xcstrings`。

## Key 命名

使用「功能.頁面或區塊.元素」的穩定 key，避免把中文原文當 key。

範例：

```swift
Text("pipLayout.statusText.section")
Toggle("outputOverlay.enable", isOn: $enabled)
Picker(String(localized: "outputOverlay.timeLayer.content"), selection: $format) { ... }
```

目前已使用的 key 類型：

- `settings.*`：設定頁入口與頁面標題。
- `pip.default.*`：PIP 預設狀態文字。
- `pipLayout.*`：PIP 排版加工頁。
- `outputOverlay.*`：輸出畫面加工頁。
- `overlayAnchor.*`、`timeFormat.*`、`fontWeight.*`：可重用選項名稱。
- `common.*`、`unit.*`：通用操作與單位。

## Swift 寫法

- SwiftUI 靜態文字優先用 `Text("key")`、`Toggle("key", ...)`。
- 需要傳 `String` 的地方用 `String(localized: "key")`，例如 `navigationTitle`、`Picker` label、`TextField` placeholder。
- 動態組合字串先取本地化 label，再和數字組合，避免把完整中文句子硬寫進程式碼。

## 使用者自訂文字

PIP 的「現在時間 / 直播中 / 直播已結束」可以讓使用者自行輸入，所以儲存邏輯採 override：

- `PIPNowTimeLabelOverride`
- `PIPLiveLabelOverride`
- `PIPEndedLabelOverride`

這三個 key 空白時代表跟隨目前系統語言，不會把某個語系的預設文字寫死到 UserDefaults。使用者有輸入時才覆蓋本地化預設值，並限制最多 12 個字，避免擠壓 PIP 的時間與狀態徽章。

## 後續翻譯流程

1. 新增 UI 字串時，先在 `liveAPP/Localizable.xcstrings` 補一個穩定 key。
2. 先填 `zh-Hant` 原文，再補 `en` 與 `ja`。
3. 程式碼只引用 key，不直接寫中文 UI 文案。
4. 用 Xcode 或裝置語言切換檢查畫面。常用測試方式是啟動參數加入 `-AppleLanguages (en)` 或 `-AppleLanguages (ja)`。
5. 翻譯完成後檢查長字串是否擠壓按鈕、Stepper、PIP 預覽與 16:9 輸出預覽。

後續如果要一次整理全 app，可以先用 `rg '"[^"]*[一-龥][^"]*"' liveAPP -n` 找出剩餘硬編碼中文，再分頁面搬到 `Localizable.xcstrings`。
