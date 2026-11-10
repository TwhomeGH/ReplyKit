# 版本標記說明

Release tag 只保留 `x.y.z`；標記由 CI 讀取 tag 之間的變更與 commit trailer 自動產生，寫入 GitHub Release 名稱與 body。Tag 本身不帶 `-Core`、`-Exp` 等字樣，以免影響 AltStore URL 與 tag 遞增規則。

## 自動分類

| 標籤 | 觸發方式 |
| ------ | ------ |
| `Core` | `SharedCapture/**`、`ReplyKIT/**`、`liveAPP/Capture/**`、`liveAPP/Audio/**`、`liveAPP/Networking/**`、`liveAPP/Recording/**`、`Package.resolved`、Metal shader |
| `UI` | `*View.swift`、`Settings/**`、`PIPLayout*`、`Localizable.xcstrings`、Artwork |
| `Audio` / `Video` / `RTMP` / `PiP` / `Extension` / `Settings` | 對應路徑變更；Release 名稱最多列 3 個 |
| `Exp` | 最近 5 個 release 內有 `Core` 變更；含目前版本，第 5 個之後自動移除 |
| `UIFix` | UI 變更且 commit 只有 `fix` 類型（沒有 `feat`） |
| `Hotfix` / `Major` | 必須在 commit 加 `Release-Label: Hotfix` 或 `Release-Label: Major`；不從訊息猜測 |
| `Stable` | 沒有 `Exp`、`Hotfix`、`Major`、`UIFix` 時自動標示 |

Release 名稱格式：

```text
17.5.5 · Core · Audio+RTMP · Exp
17.5.6 · UI · PiP · UIFix
17.5.7 · Core · Video · Hotfix
17.5.8 · Stable
```

`Exp` 是以 tag 歷史重新計算，不保存額外狀態：

- `V` 有 Core 變更 → `V`～`V+4` 標 `Exp`。
- `V+5` 起不再標，除非又有新的 Core 變更。
- 若中途又有 Core 變更，從該版本重新起算。

## 人工覆寫

語意上無法自動判斷的標籤用 commit trailer：

```text
Release-Label: Hotfix
Release-Label: Major, UIFix
```

同一版可有多個標籤；`Hotfix`／`Major` 會優先於自動產生的 `Stable`。分類規則與測試在 `Scripts/release_classification.json`、`Scripts/classify_release.py` 與 `Scripts/test_classify_release.py`。

## MARKETING_VERSION 與 Release tag

Archive／Release workflow 會讀取 `x.y.z` tag，並在 `xcodebuild archive` 加上：

```text
MARKETING_VERSION=<tag>
```

這是 Xcode command-line build setting override，會讓主 App 與所有 extension 的 `CFBundleShortVersionString` 使用同一個 tag，不需要先手動修改 `project.pbxproj`。CI 會輸出：

```text
MARKETING_VERSION old=17.6.7 -> effective=17.6.8
Archived app version: CFBundleShortVersionString=17.6.8
```

- 本地忘記改 `MARKETING_VERSION` 時，CI 產物仍會使用 tag 版本。
- repo 內的 `project.pbxproj` 不會被 CI 改寫，因此本地 Xcode 建置仍以手動值為準。
- 測試 target 的 `MARKETING_VERSION = 1.0` 是刻意設定，不列入 release 版本比對。
- `CURRENT_PROJECT_VERSION` 目前仍由專案／人工控制，不由此步驟自動改寫。

## Why Too Many Versions？為什麼會出現這麼多版本？

這是因為專案開發初期，主要是在本地 Xcode 環境進行開發與測試。

當時我是透過 OpenCore，將 2014 款 MacBook Pro 升級到 macOS 15.7 作為開發環境。然而，隨著 macOS 26 推出後
這台舊款 MacBook 的系統環境受到影響，導致無法正常作為 Xcode 開發機使用。後續可能需要重新回退至 macOS 15.7，才能恢復穩定的開發環境。

不過，在處理系統的過程中遇到了不少困難，包含 EFI 設定反覆調整與除錯，仍然無法順利解決問題。因此，我暫時將這台 Mac 擱置，避免花費過多時間在系統修復上，影響專案開發進度。

為了讓開發不中斷，我改採 GitHub Actions（GitHub Workflow）進行遠端建置。現在的開發流程大致為：修改程式碼 → 推送至 GitHub → 自動建置 App → 側載到裝置進行測試。

雖然這種方式比直接使用 Xcode 本地開發更繁瑣、建置速度也較慢，但至少能在缺少本地開發環境的情況下，持續推進專案開發，而不至於完全停擺。

## 贊助與支持

如果這個專案對你有所幫助，並希望支持專案持續開發，非常感謝你的支持。

為什麼需要支持？

本專案最初是使用 OpenCore + 2014 款 MacBook Pro 建立 Xcode 本地開發環境，並長期在該環境下進行開發與測試。

然而，隨著新版 macOS 推出，OpenCore 與舊硬體的相容性受到影響，原本穩定的開發環境遭到破壞
雖然曾嘗試透過調整 EFI、重新設定 OpenCore 等方式修復，但仍無法恢復到原本可正常開發的狀態，因此目前暫時停止在該設備上的本地開發。

為了不讓專案因此停擺，目前改採 GitHub Actions（GitHub Workflow） 作為替代方案，開發流程大致如下：

修改程式碼 → 推送至 GitHub → GitHub 自動建置 → 側載到裝置測試

雖然這種方式仍能持續開發，但每次修改都需要等待遠端建置完成，無法像 Xcode 一樣即時除錯、測試與迭代，因此整體開發效率明顯降低。

如何支持這個專案？

如果你希望協助專案持續發展，以下幾種方式都能提供很大的幫助：

- 提供可用於 Xcode 開發的 Mac 設備（借用或捐贈皆可）。
- 提供可使用的開發空間或設備資源（例如學校、社群空間、Maker Space 等）。
- 其他任何能協助改善開發環境的資源。

如果你位於台灣，且願意提供設備或相關資源，歡迎加入 Discord 社群與我們聯繫。

你的每一份支持，都能讓專案更穩定地持續開發，也能加快新功能與修正的推出速度。謝謝你的支持！
