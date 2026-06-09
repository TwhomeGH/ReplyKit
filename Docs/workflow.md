# 本地建置工作流程

## 修改 Metal Shader（.metal）後的正確建置方式

`ReplyKIT/rotateNV12.metal` 使用 **Xcode File System Synchronization**（`PBXFileSystemSynchronizedRootGroup`）自動納入專案。理論上 Xcode 會自動偵測 .metal 檔案的變更並重新編譯，但**實際上有時 Metal shader cache 不會失效**，導致執行時用的仍是舊的 `default.metallib`。

### 症狀

- 修改 .metal 後「無效」（新 kernel 找不到、舊行為不變）
- `makeFunction(name:)` 回傳 nil
- Debug log 出現「建立 ComputePipeline 失敗」

### 解法一：Clean Build Folder（最快）

在 Xcode 選單：

```
Product → Clean Build Folder（按住 Option 鍵會變成 Clean Build Folder）
```

或快捷鍵：`⌃⇧⌘K`

再重新 Build（`⌘B`）。

### 解法二：清除 Metal Cache Script

專案已附帶清除腳本：

```bash
# 終端機執行
./Scripts/clean_metal_cache.sh
```

然後在 Xcode 中重新 Build。

### 解法三：在 Xcode 中加入 Run Script Build Phase（一次性設定）

如果想**永久解決**，可以在專案中加入一個 Pre-build Run Script Phase：

1. 點選專案 → Target → **Build Phases**
2. 點擊 **+** → **New Run Script Phase**
3. 拖到 **Compile Sources** 之前
4. 貼上以下內容：

```bash
# 每次 Build 前清除 Metal cache，確保 .metal 強制重新編譯
DERIVED=$(echo "$DERIVED_DATA_DIR" | sed 's|^file://||')
if [ -n "$DERIVED" ]; then
    rm -rf "$DERIVED/Build/Intermediates.noindex/ShaderCache" 2>/dev/null
fi
```

這樣每次 Build 前都會清空 ShaderCache，保證 .metal 重新編譯。

---

## CI/CD 自動建置（GitHub Actions）

### 觸發條件

修改以下路徑的檔案會觸發自動建置：

- `liveAPP/**/*`
- `ReplyKIT/**/*`

### 建置流程

1. **tag.yaml** — 偵測變更 → 自動建立遞增版號的 tag
2. **main.yml** — tag 被建立後 → `xcodebuild clean` + `archive` → 產出 unsigned IPA → 上傳 Release

### 注意

`main.yml` 的 Build & Archive 步驟已包含 `xcodebuild clean`，所以 CI 環境**不會有 cache 問題**。此問題僅發生在本機開發。
