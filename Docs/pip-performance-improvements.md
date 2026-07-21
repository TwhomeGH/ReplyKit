# PiP 性能優化 (2026-07)

## 概述

改善子母畫面（PiP）渲染管線的多項效能瓶頸：

- 移除不必要的 async hop（actor → Task → MainActor）
- 加入 dirty flag 避免無變化時仍每秒產生 pixel buffer
- 消除配置（layout）重複計算

---

## 1. 移除 PIPRenderPipeline actor

### `liveAPP/PIPService.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| 每幀 3 次 async hop | timer → `Task { await actor.requestRender() }` → `actor.loop()` → `MainActor.renderIncremental()` | 直接 `Task { @MainActor in renderIncremental() }`，減少非同步切換開銷 |
| actor 無實際保護效果 | actor 不持有 mutable state，且 render 已由 `renderQueue` (serial) + `@MainActor` 保證序列化 | 移除 actor，render timer handler 直接呼叫 `renderIncremental()` |

## 2. Self-scheduling 取代固定間隔 timer

### `liveAPP/PIPService.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| render task 堆積造成 frame burst | 固定間隔 DispatchSourceTimer 無視前一幀是否完成，Timer fired → Task { @MainActor } 在 main thread 忙碌時大量排隊 | 改為 self-scheduling：`renderIncremental()` 結束後才呼叫 `scheduleNextRender()`，永遠只有一個待處理 render task |
| render 結束後無法停止 loop | 改用 asyncAfter 後沒有可 cancel 的 timer handle | 加入 `renderCancelled` flag，`cancelRenderTimer()` 設為 true 即可中斷迴圈 |
| FPS 快速震盪（1↔8↔1↔8） | `decayFPSIfNeeded()` 每次 render 結束立即降到 idleFPS，稀疏訊息導致頻繁切換 | 加入 2 秒 cooldown：`lastActiveRenderTime` 記錄最後一次有效 render，cooldown 內維持 activeFPS |
| idle FPS 太低、畫面凍結 1 秒 | `idleFPS = 1` 每秒只有 1 幀，時間已改 1 秒但畫面仍停滯 | `idleFPS: 1 → 4`（250ms 間隔）、`activeFPS: 8 → 10`（100ms 間隔） |
| renderQueue QoS = .background 增加延遲 | timer 在最低優先權佇列觸發，MainActor hop 前可能被高優先權任務插隊 | `qos: .background → .default`，確保 timer 觸發即時 |

### 資料流對比

```
改善前（固定間隔 timer）：
  timer(1Hz) → Task { @MainActor in renderIncremental() }
  → timer(1Hz) → timer(1Hz) → ...（排隊堆積）

改善後（self-scheduling）：
  scheduleNextRender() → asyncAfter(interval) → renderIncremental() → scheduleNextRender() → ...
  [新訊息] → setNeedsRedraw() → (下一幀即時處理)
```

## 3. 時間疊加層繪製

### `liveAPP/PIPService.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| overlay 每幀重新計算 Core Text | `drawTimeOverlay()` 每次都建立 NSAttributedString、計算 text size、繪製 badge | 快取 timeString / elapsedString / streamEnded / viewerCount / isReconnecting 用於參考，不再依此跳過繪製 |
| overlay 同一秒內閃爍消失 | 快取命中時疊加層整個不繪製，同一秒內多則訊息讓時間消失 | 移除 cache early-return，每幀均繪製疊加層；文字與 badge 繪製成本在 4 FPS idle 下可忽略 |

## 5. Memory Warning 分級釋放

### `liveAPP/PIPService.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| 短暫 memory pressure 就清空所有快取 | `handleMemoryWarning()` 每次全量釋放 | 分三級：L1=image cache + 降 FPS，L2=丟 pixelBufferPool，L3=清訊息；10 秒內連續觸發才升級 |
| 同一個 warning 觸發兩次 | `liveAPPApp` 和 `PIPService` 各自註冊 observer | 移除 `PIPService.init()` 的 observer，由 `liveAPPApp` 統一呼叫 `handleMemoryWarning()` |

## 6. Log 頁卡頓改善

### `liveAPP/liveAPPApp.swift` — LogModel

| 問題 | 原因 | 修正 |
|------|------|------|
| `removeFirst` O(1000) memmove 每批 log 都發生 | 超過 `maxMessages` 就立刻 trim | 改為 `maxMessages * 2` 才 trim，降低 main thread 阻塞頻率 |

### `liveAPP/ContentView.swift` — Coordinator

| 問題 | 原因 | 修正 |
|------|------|------|
| `trimTextStorageIfNeeded` 5-pass 全量文字重建 | `components(separatedBy:)` + filter + suffix + concat + `tv.text=` | 改用 `textStorage.replaceCharacters(in:)` 範圍刪除，跳過全部 copy |
| 每批 append 兩次 `layoutIfNeeded` | CATransaction block 內外各一次 | 移除 CATransaction wrapper，只保留一次 `layoutIfNeeded`，scroll 直接呼叫 |

## 7. PiP 活躍時跳過 bgTask

### `liveAPP/BackgroundTaskManager.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| PiP 使用時仍啟動 `beginBackgroundTask` + `BGTaskScheduler` | 不檢查 PiP 狀態 | `scheduleSocketRefresh()` / `beginSocketBackgroundWindow()` 開頭檢查 `PIPService.shared.isPiPActive`，跳過多餘背景任務 |

## 8. 前景重建 + 強制重繪

### `liveAPP/PIPService.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| 通知欄/控制中心關閉後 PiP 黑畫面 | `appWillEnterForeground()` 非同步 re-attach 與 render timer 有 window | 結束前呼叫 `forceRender()`（setNeedsRedraw + 立即 `Task { @MainActor in renderIncremental() }`） |

---

## 檔案變更

### `liveAPP/PIPContent.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| `relayoutTargetsOnly()` 在 `addMessage` 流程被呼叫兩次 | `populateVisibleMessagesIfNeeded()` + `layoutTargetsAndStartAnimation()` 各自呼叫一次 | 移除 `populateVisibleMessagesIfNeeded()` 內的呼叫（由後者統一計算）；`reloadPending()` 補上自己的呼叫 |

受惠路徑：
- `addMessage()` → `populateVisibleMessagesIfNeeded()` + `layoutTargetsAndStartAnimation()`
- `removeMessage()` → `populateVisibleMessagesIfNeeded()` + `layoutTargetsAndStartAnimation()`
- `onMoveFinished()` → `populateVisibleMessagesIfNeeded()` + `layoutTargetsAndStartAnimation()`

## 9. SocketServer 保持常駐 + 移除 per-connection idle timer

### `liveAPP/Socket.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| 1 小時無連線後 server 自殺 | `startActivityIdleTimer(3600)` 在 `start()` 和 `removeConnection()` 最後連線移除時啟動 | 改為 no-op，`NWListener` 持續監聽，永不自動關閉 |
| Per-connection 60s idle timer 在多頁快速切換時造成連線被誤關 | `resetIdleTimer()` 每條連線獨立 60s timer，audioPage↔logPage 頻繁切換產生大量連線，部分被 idle timeout 錯誤關閉 | 完全移除 per-connection idle timer (`idleTimers` dictionary、`resetIdleTimer()`、所有 call site)；改用 NWConnection state 監控 + `maxConnections` 限制做 cleanup |
| `stopInternal()` 無謂操作 `idleTimerActivity` | activity timer 已廢除但仍嘗試 cancel | 移除相關代碼 |

## 10. NSCache 自動回收取代 Memory Warning 強制清除

### `liveAPP/PIPContent.swift` / `liveAPP/PIPService.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| Memory Warning 時 `PiPImageCache.shared.clear()` 清空 NSCache | 但 NSCache 在 memory pressure 下已自動 evict，手動清空浪費已緩存的圖片 | 移除所有 `PiPImageCache.shared.clear()` 呼叫，完全信賴 NSCache.countLimit / totalCostLimit 自動回收 |
| `releaseNonCriticalMemory()` 進入背景時也清 cache | 背景一段時間後回 foreground 所有圖片需重新下載 | 移除 cache clear，保留 PiP 非活躍時的 render 資源釋放 |

## 11. Pixel buffer 移除 UIScreen.main.scale

### `liveAPP/PIPService.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| pixel buffer 多出 4x~9x 無謂像素 | `OframeSize = frameSize * scale` 導致 300x200 pt → 600x400 (2x) / 900x600 (3x) | 直接設 `OframeSize = size`，CPU Core Graphics 繪製解析度獨立，300x200 已清晰 |
| memset / CALayer.render 浪費 4x~9x 頻寬 | 每幀 `memset(bytesPerRow * height)` 作用於 4x~9x 大小的 buffer | 每幀 memset 量降至 1/4~1/9，CALayer.render 同上比例縮減 |
| render pipeline 中多餘 scale transform | `context.scaleBy(x: scale, y: scale)` 縮放後 overlay/caLayer 再繪製 | 移除所有 scaleBy 呼叫，直接在 1x 座標空間繪製 |

## 12. PIPService isPiPActive 雙向同步

### `liveAPP/PIPService.swift` / `liveAPP/PIPContent.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| 用戶關閉 PiP 系統按鈕後 UI 仍顯示啟用 | `PIPView` 用 `@State isChatPiPActive` 自行管理狀態，不跟 `PIPService.didStartPiP` 同步 | `didStartPiP` → `@Published var isPiPActive`，`PIPService` 遵從 `ObservableObject` |
| `PIPView` 按鈕 disabled 狀態不同步 | 按鈕綁定 `@State` 而非實際 `isPiPActive` | `PIPView` 使用 `@ObservedObject var pipService = PIPService.shared`，按鈕直接讀取 `pipService.isPiPActive` |

## 13. ReplyKIT PTS 管線審查

### `ReplyKIT/AudioProcess.swift` / `ReplyKIT/GPUVideoRotator.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| Audio PTS 無 monotonic 保護 | `retimeAudioBuffer()` 複製原始 timing 但不做任何校正，若 ReplayKit 送來倒退的 PTS 會直接餵給 MediaMixer | 追蹤 `lastAudioPTS`，新 PTS 倒退時 clamp 到上一次值；倒退 >0.5s 時 log 警告 |
| `currentPTS` 死碼 | 宣告 `.zero` 後從未被賦值 | 移除 |
| `GPUVideoRotator.lastPTS` 死碼 | 宣告 `nil` 後從未被賦值或讀取 | 移除 |

其餘管線（VideoProcess → GPUVideoRotator/CPURotator → MediaMixer）均為純透傳 ReplayKit 原始 PTS，無合成/修改，無 PTS 倒轉風險。

## 13. 頁面切換頻率保護

### `liveAPP/ContentView.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| audioPage 與 logPage 快速切換造成大量連線建立與取消 | 每次 `onChange(of: currentPage)` 立即發送 Darwin notification，extension 收到後建立 E-Socket 連線請求 config | 加入 300ms debounce：`DispatchWorkItem` + `asyncAfter`，快速切換只處理最後一次 |

---

## 14. 子母窗口行內表情支援（Inline Emoji）

### `liveAPP/PIPContent.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| Socket stream 訊息的 `message` 欄位包含圖片網址（`https://example.com/3.png 哈哈哈`），但 PiP 將其整個視為純文字渲染 | 無圖片網址解析機制，所有文字直接餵給 `CATextLayer` | 新增 `extractImageURL()` 正則解析，擷取結尾為 `.png/.jpg/.gif/.webp` 的網址，分別以 `CALayer` 顯示圖片、`CATextLayer` 顯示剩餘文字 |

### 資料流

```
Socket message: "https://example.com/3.png 哈哈哈"
  → extractImageURL()
    → cleaned: "哈哈哈"
    → emojiURL: "https://example.com/3.png"
  → splitLongMessage() 分行 "哈哈哈"
    → 第一個 message segment 取得 inlineEmojiURL
  → buildMessageTuple() 建立 CATextLayer + 表情 CALayer
  → PiPImageCache 非同步載入表情圖片
  → 子母窗口顯示: [名稱] [表情圖] 哈哈哈
```

### 模型變更

| 型別 | 新增欄位 | 用途 |
|------|----------|------|
| `MessageSegmentData` | `inlineEmojiURLs: [String]` | 存放從訊息文字解析出的所有圖片網址（支援多個） |
| `MessageLayerTuple` | `inlineEmojis: [CALayer]` | 表情圖片的 Core Animation 圖層陣列 |
| `MessageLayerTuple` | `inlineEmojiSizes: [CGSize]` | 表情圖層大小快取陣列 |

### 渲染行為

- 表情圖片僅附加於**第一個文字 segment**（`index == 0`），避免多行重複顯示
- 支援**多個表情**同時顯示，依序水平排列於訊息文字起始處
- 表情圖層定位在**名稱文字後方**，垂直居中於訊息文字列
- 表情圖層與 avatar/gift 共用 `LayerPool` 的 image layer 回收機制
- 表情圖片透過 `PiPImageCache` 載入，支援 NSCache 快取與 concurrent 限制
- 淡出動畫、移除回收一併處理表情圖層

---

## 15. PiP 渲染優化（CPU 路徑）

### 最終決策

| 方案 | 測試結果 | 結論 |
|------|----------|------|
| 1x pixel buffer（300x200） | 效能佳但 Retina 螢幕模糊 | ❌ 捨棄 |
| scale pixel buffer + CPU 繪製（目前方案） | 穩定、清晰、效能足夠 | ✅ 採用 |
| Metal GPU 全管線（textured quad + 文字 bitmap） | 複雜度高、premultiplied alpha 與文字渲染品質難調 | ❌ 暫緩 |

**觀察**：CPU 路徑在 idle 4 FPS / active 10 FPS 下，`CVPixelBuffer` 的 IOSurface 特性讓 display layer 讀取近乎零成本；`CGContextFillRect` 取代 `memset` 維持穩定幀率，無掉幀或卡頓。Metal 版的文字渲染品質問題（粉筆灰效應、premultiplied alpha blend 不正確）耗費大量除錯時間，且 CPU 路徑已滿足效能需求，**Metal 版本無立即必要**。

### 現行 CPU 路徑設計

```
pool → CVPixelBuffer(IOSurface) → LockBaseAddress
  → CGContextFillRect（取代 memset）
  → CALayer.render(in:) (scale transform 2x/3x)
  → drawTimeOverlay (scale transform 2x/3x)
  → Unlock → CMSampleBuffer → displayLayer
```

### Metal 實驗保留檔案

`PIPMetalRenderer.swift`、`PIPMetalRenderData.swift`、`PIPShaders.metal` 保留但不啟用，供日後參考。

### 最終參數

| 項目 | 值 |
|------|-----|
| pixel buffer 尺寸 | `frameSize × UIScreen.main.scale`（300×200 → 600×400 或 900×600） |
| idle FPS | 4 |
| active FPS | 10 |
| animation FPS | 24 |
| periodic redraw | 1s |
| render 排程 | self-scheduling（完成一幀才排下一幀） |
| clear | `CGContextFillRect(.black)` |
| 文字繪製 | CPU Core Graphics |

## 檔案變更

## 檔案變更

## 檔案變更

| 檔案 | 行數變化 |
|------|----------|
| `liveAPP/PIPService.swift` | -46 (actor) +80 (dirty flag, overlay cache, periodic redraw) +22 (tiered memory, forceRender, isPiPActive) ~40 (self-scheduling, renderCancelled, cooldown, FPS tune) -2 (移除 PiPImageCache.clear) +3 (ObservableObject, @Published) |
| `liveAPP/PIPContent.swift` | -1 (redundant layout) +1 (reloadPending guard) -3 (~PIPView @State 改 @ObservedObject) |
| `liveAPP/PIPMetalRenderer.swift` | +66 (新檔，僅 GPU clear, 未啟用) |
| `liveAPP/PIPMetalRenderData.swift` | +20 (新檔，資料結構, 未啟用) |
| `liveAPP/PIPShaders.metal` | +30 (新檔，Metal shaders, 未啟用) |

---

## 16. 行內表情圖改進（2026-07）

### `liveAPP/PIPContent.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| Discord CDN 圖片網址（`...jpg?ex=...&hm=...`）因 query parameters 不被 regex 匹配，整個 URL 當純文字顯示 | `extractAllImageURLs` 的 regex `[^\s]+\.(ext)` 只匹配到副檔名，query string 殘留在 clean text | 加上 `(\?[^\s]*)?` 讓 query string 成為 URL 一部分（:1023） |
| URL 全部抽出後 clean text 為空，無 message segment 導致 emoji 無處附著不顯示 | `splitLongMessage` 在 message 空字串時不產生 message segment，`inlineEmojiURLs` 遺失 | `addMessage` 判斷 clean text 為空但有 emoji URLs 時以 `" "` 代替（:1091） |
| 下載後 inline emoji 以原始解析度顯示（如 400×400），遠大於字體大小 | `inlineEmojiSizes[idx] = imgSize` 直接取用實際圖片尺寸 | 改為 `min(maxSize/width, maxSize/height)` 等比縮放至字體大小（:1281-1286） |
| Emoji 與文字重疊，`emojiCursorX = messageFrame.minX` 使圖片蓋在文字上 | 圖片從文字左緣開始排列，與文字完全重疊 | 改為 `messageFrame.maxX`，排到文字右側（:1866） |

---

## 17. Memory Warning 分級釋放廢除（2026-07）

### `liveAPP/PIPService.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| `memoryWarningLevel` 循環升級（L1=L2=L3）：10 秒內連續觸發才逐步加重，但 warning 已結束仍遺留高級別 | cooldown timer + level counter 設計使同一次 memory pressure 週期中 level 只增不減，容易卡在高級別狀態 | 移除 `memoryWarningLevel` / `lastMemoryWarningTime` / `memoryWarningCooldown` 全部變數，收到 warning 直接一次釋放所有可回收資源 |
| L1（降 FPS）沒有實際釋放記憶體 | `currentFPS = idleFPS` 僅降低渲染頻率，不釋放 pixel buffer | 不再操作 FPS，FPS 由 animation/decay 機制獨立管理 |
| `PiPImageCache` 未在 memory warning 時清空 | 舊設計僅 L3（level>=3）才清訊息，image cache 完全沒被觸及 | `handleMemoryWarning` 最後加上 `Task { await PiPImageCache.shared.clear() }` |

```swift
// before: 分級釋放
func handleMemoryWarning() {
    let now = CACurrentMediaTime()
    if now - lastMemoryWarningTime < memoryWarningCooldown { level += 1 }
    else { level = 1 }
    currentFPS = idleFPS
    if level >= 2 { pixelBufferPool = nil }
    if level >= 3 { messagesLayer?.clearAllMessages() }
}

// after: 一次釋放
func handleMemoryWarning() {
    pixelBufferPool = nil
    cachedFormatDescription = nil
    cachedFormatSize = .zero
    messagesLayer?.clearAllMessages()
    Task { await PiPImageCache.shared.clear() }
    setNeedsRedraw()
}
```

---

## 18. TTS Audio Session 配置修正（2026-07）

### `liveAPP/TTSService.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| PIP `stopPiP()` 在 TTS disabled 時 `setActive(false)` deactivate 了 audio session，但 TTS 的 `isConfigured` flag 維持在 `true`，後續每次 `start()` 都跳過重新配置 | `configureSessionOnly()` 開頭 `guard !isConfigured` 阻斷重入 | 移除 `isConfigured` guard，每次 TTS 啟動都重新呼叫 `setCategory`/`setActive(true)`（冪等呼叫，已配置時無副作用） |

```swift
// before
func configureSessionOnly() {
    guard !isConfigured else { return }
    try configurePlaybackSession()
    isConfigured = true
}

// after
func configureSessionOnly() {
    try configurePlaybackSession()
    isConfigured = true
}
```

---

## 19. Socket BGTask 與 Keepalive 改進（2026-07）

### `liveAPP/BackgroundTaskManager.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| PIP 活躍時 `scheduleSocketRefresh()` 直接 return，不排程下一次 BGTask。PIP 長時間運作後停止時無 pending task 可喚醒 App | `guard !PIPService.shared.isPiPActive` 導致 PiP active 時跳過排程 | 移除 PIP guard，永遠排程下次 refresh（15 分鐘後） |

### `liveAPP/Socket.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| NWConnection 60 秒無資料後自動 idle timeout 關閉連線，extension 不會自動重連 | 無 server 端 keepalive 機制 | 新增定時器：首條連線建立後每 30 秒對所有連線廣播 `{"type":"keepalive"}`，最後一條連線移除時停止 |
| `stopInternal()` 與 `removeConnection()` 未清理 keepalive timer | timer 無對應的生命週期管理 | `stopInternal()` + `removeConnection`(last) 時呼叫 `stopKeepaliveTimer()` |

```swift
private func startKeepaliveTimer() {
    stopKeepaliveTimer()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 30, repeating: 30)
    timer.setEventHandler { [weak self] in
        self?.sendKeepalive()
    }
    timer.activate()
    keepaliveTimer = timer
}

private func sendKeepalive() {
    let payload: [String: Any] = ["type": "keepalive"]
    for conn in connections.values {
        sendTo(conn, payload: payload)
    }
}
```

---

## 20. 行內表情去重與下載佇列改進（2026-07）

### `liveAPP/PIPContent.swift` — PiPImageCache

| 問題 | 原因 | 修正 |
|------|------|------|
| 相同網址重複出現時，第二個請求因 `inFlightTasks[url] != nil` 直接 `return`，不呼叫 completion，第二個表情圖層永遠空白 | 僅防止重複下載但未保存待通知的 callback | 新增 `pendingCallbacks: [String: [(UIImage?) -> Void]]`，在飛中的 URL 後續請求排入佇列，下載完成後遍歷所有 callback 通知 |

```swift
// before
if inFlightTasks[urlString] != nil {
    return  // 第二個請求直接被丟棄
}

// after
if inFlightTasks[urlString] != nil {
    pendingCallbacks[urlString, default: []].append(completion)
    return  // 排入佇列，等第一筆下載完成後統一通知
}
```

### `liveAPP/PIPContent.swift` — extractAllImageURLs

| 問題 | 原因 | 修正 |
|------|------|------|
| `maxURLs` 預設值 5 過低，一次實況貼圖包可能超出 | 限制太嚴格，用戶體驗不佳 | 放寬至 20，配合 PiPImageCache callback 佇列，重複 URL 只下載一次、其餘從快取取用 |

### `liveAPP/liveAPPApp.swift` — postSystemNotification

| 問題 | 原因 | 修正 |
|------|------|------|
| 通知僅附帶使用者頭像，訊息內的圖片網址被當純文字顯示 | `postSystemNotification` 只收 `imageURL` 參數 | 新增 `inlineImages: [String]`，`DispatchGroup` 平行下載所有圖片，全部完成後一次發送通知 |

```swift
func postSystemNotification(title: String, body: String, imageURL: String? = nil, inlineImages: [String] = []) {
    // ...
    for url in allURLs {
        group.enter()
        URLSession.shared.dataTask(with: url) { data, _, error in
            // 下載並建立 UNNotificationAttachment
        }.resume()
    }
    group.notify(queue: .main) {
        content.attachments = attachments
        deliverNotification(content: content)
    }
}
```

### `liveAPP/Socket.swift` — renderChatMessage

| 問題 | 原因 | 修正 |
|------|------|------|
| 通知 body 為原始 `msg`（含未解析的圖片網址），且未傳遞 inline 圖片 | 未對 `msg` 做 URL 抽取 | 呼叫 `PIPServiceMessages.extractAllImageURLs(from: msg)` 取出圖片網址，與頭像一併傳入 `postSystemNotification` |

```swift
let inlineImages = PIPServiceMessages.extractAllImageURLs(from: msg).imageURLs
postSystemNotification(title: user, body: msg, imageURL: img, inlineImages: inlineImages)
```

### `ReplyKIT/Socket.swift` — keepalive 回應

| 問題 | 原因 | 修正 |
|------|------|------|
| Server 每 30s 發 `{"type":"keepalive"}`，但用戶端無對應 handler，打 `default` 記錄 Unknown type | 用戶端缺少 `case "keepalive"` | 新增 `case "keepalive": sendPayload(["type": "heartbeat"])`，形成雙向 keepalive 防止任一端 idle timeout |

---

## 21. 移除 forceFlushBatch 與 sendLog 順序規範（2026-07）

## 22. UPSet 伺服器端改進與頁面切換連線優化（2026-07）

### `ReplyKIT/SampleHandler.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| 每次切換日誌頁/音訊頁時，extension 先讀 `SharedDefaults`，再發 `requestSet` (UPSet) 透過 socket 向 liveAPP 重新索取同一值 | 兩邊已共用 `group.nuclear.liveAPP` App Group UserDefaults，main app 寫入後 post Darwin notification，extension handler 讀取時值已就緒，UPSet 完全多餘 | 移除 `requestSet` 呼叫，handler 直接使用 `SharedDefaults.group?.bool(forKey:)` |

```swift
// before: 2 次 read（SharedDefaults + UPSet socket）
var logPage = SharedDefaults.group?.bool(forKey: "onlogPage") ?? false
if RPConfig.shared.enableSocketLog {
    if let raw = try await SocketClient.shared.requestSet(for: "onlogPage", type: "Bool") {
        if let av = raw as? Bool { logPage = av }
    }
}

// after: 1 次 read（SharedDefaults，無 socket）
let logPage = SharedDefaults.group?.bool(forKey: "onlogPage") ?? false
RPConfig.shared.onLogPage = logPage
```

**效果：** 非側載時頁面切換不再需要建立 socket 連線；側載時透過 UPSet 取得，且連線在 UPSet 回應後保持不關閉，後續 UPSet 可重複使用。

### `liveAPP/Socket.swift` — 伺服器端 UPSet 改進

| 問題 | 原因 | 修正 |
|------|------|------|
| `bool(forKey:)`/`integer(forKey:)` 對不存在的 key 回傳 `false`/`0`，無法區分「不存在」與「值為 false/0」 | Apple API 設計：UserDefaults 的 primitive 讀取方法對缺失 key 回傳型別預設值 | 改用 `object(forKey:) as? Bool/Double/Int/Float`，key 不存在時回傳 `NSNull()` |
| 客戶端 UPSet handler 收到回應後立刻 `_closeConnection()` | on-demand 設計，每次 UPSet 連線用完即關 | 移除 `_closeConnection()`，連線保留供後續 UPSet 重複使用，由 idle timeout 或下一次 `_connect()` 清理舊連線時自然關閉 |

```swift
// before
res = userDefaults?.bool(forKey: key)  // 不存在 → false，無法區分
// after
res = userDefaults?.object(forKey: key) as? Bool  // 不存在 → nil → NSNull()
```

### `ReplyKIT/SampleHandler.swift` — 頁面切換 handler

| 問題 | 原因 | 修正 |
|------|------|------|
| `onlogPage`/`onAudioPage` handler 每次都透過 UPSet 向伺服器索取已存在 SharedDefaults 的值 | 多餘的 socket 連線造成連線數暴增與 close/reconnect 開銷 | 非側載時直接讀 SharedDefaults（同一 App Group，值已就緒）；側載時才用 UPSet 取得 |
| `requestSet` 16 個 handler（音量、旋轉等）各自獨立連線 | 每個 handler 在 CFNotification 觸發時建立獨立連線 | UPSet 連線不再主動關閉，後續 requestSet 可重複使用同一連線 |

### `ReplyKIT/SampleHandler.swift` — 頁面切換重構

| 問題 | 原因 | 修正 |
|------|------|------|
| `onlogPage` handler 中 inline 邏輯與 `applyOnLogPage` 方法不存在造成編譯錯誤 | 先前 patch 殘留未定義的方法呼叫 | 拆為 `updateLogPageState()`（負責獲取值，區分側載/UPSet）與 `applyLogPage(_:)`（負責套用狀態） |
| `forceFlush()` 在頁面切換時被呼叫，但 `forceFlush()` 會 cancel timer + 設 `isActive = false`，與後續 `setupFlushTimer()` 原子性不足，中間 window 的 log 會被丟棄 | `forceFlush()` 設計為「關閉 logging pipeline」，不適合僅切換頁面狀態 | 完全移除頁面 handler 中的 `forceFlush()`：切 ON 只 `setupFlushTimer()`，切 OFF 只 `discardBuffer()` |

```swift
// before: forceFlush + setupFlushTimer 重置 pipeline
if logPage {
    LogManager.shared.forceFlush()      // 關閉 timer + isActive=false
    LogManager.shared.setupFlushTimer() // 重新開啟
} else {
    LogManager.shared.forceFlush()      // 關閉 pipeline
}

// after: 直接切換狀態
if logPage {
    LogManager.shared.setupFlushTimer()  // 啟動/重啟 timer
} else {
    LogManager.shared.discardBuffer()    // 清空 buffer，timer 自然過期
}
```

| 新增方法 | 所屬類別 | 用途 |
|----------|----------|------|
| `updateLogPageState()` | `SampleHandler` | 閱讀頁面狀態（SharedDefaults / UPSet），非同步取得後呼叫 `applyLogPage` |
| `applyLogPage(_:)` | `SampleHandler` | 套用頁面狀態：ON → 啟動 timer，OFF → 丟棄 buffer |
| `discardBuffer()` | `LogManager` | 清空 ring buffer（`localLogBuffer.removeAll()`），在 logQueue barrier 中安全執行 |

### `ReplyKIT/Socket.swift` — 刪除 forceFlushBatch

| 問題 | 原因 | 修正 |
|------|------|------|
| `forceFlushBatch()` 使用 `queue.sync {}` 阻塞呼叫端，在 HaishinKit 媒體操作路徑上造成同步 I/O，加劇 C++ buffer overflow 對 string buffer 的破壞 | 強制立即發送日誌的設計在瓶頸路徑上增加了阻塞與記憶體壓力 | 移除整個 `forceFlushBatch()` 方法 |

```swift
// 已刪除
func forceFlushBatch() {
    queue.sync {
        _connect()  // 同步建立連線
        sendPayload(payload)  // 同步發送
    }
}
```

### `ReplyKIT/Event.swift` — forceFlush call site 改為非同步

| 問題 | 原因 | 修正 |
|------|------|------|
| `forceLogFlush` 和 `flushLocalLogs` 在送出 batch 後立即呼叫 `forceFlushBatch()`，阻塞直到日誌送達 server | 設計假設日誌必須在繼續前送達，但 log pipeline 不需要即時性 | 改為 `sendLogBatch(entries:, force: true)`，內部 `flushBatch()` 在 serial queue 上非同步處理 |

### 設計變更總結

| 面向 | 改前 | 改後 |
|------|------|------|
| 日誌傳送 | `forceFlushBatch()` 阻塞直到連線+發送完成 | `flushBatch()` 非同步排入 serial queue |
| sendLog 呼叫時機 | 必須在 HaishinKit 操作「之前」，否則可能觸發已破壞的 string buffer | 無順序要求 — log 僅 append 到 ring buffer（固定 1000 條 O(1)），不碰媒體管線 |
| 丟棄策略 | force flush 會繞過 `maxInflightBatches` 限制，造成堆積 | 依賴 `maxInflightBatches=3` 硬限制，逾限自動 drop 最舊 batch |
| 定時器 | 250ms batch timer + 同步 force flush | 僅 250ms batch timer，無同步 flush |

---

## 23. 行內表情載入修復（2026-07）

### `liveAPP/PIPContent.swift` — PiPImageCache.loadImage

| 問題 | 原因 | 修正 |
|------|------|------|
| 相同網址快取命中時 completion 在 actor context（非主執行緒）執行，設定 `CALayer.contents` 有執行緒風險 | 原 code 直接 `completion(img)` 未 dispatch 到 MainActor | 快取命中時以 `await MainActor.run { completion(img) }` 派發至主執行緒 |
| `UIImage(data:)` 回傳 nil（伺服器回傳非圖片資料，如 GitHub blob HTML）時，第一個 caller 的 completion 完全未被呼叫，對應 emoji 圖層永遠空白 | `if let img = UIImage(data: data)` 的 else 分支直接跳過，未呼叫 `completion` 也無 pending callbacks 通知 | 加入 else 分支，以 `await MainActor.run { completion(nil); for cb in callbacks { cb(nil) } }` 確保所有 callback 都收到 nil |
| 無效 URL 時僅呼叫 `finishDownload`，不通知 caller | `guard let url = URL(...)` 的 else 分支遺漏 callback 處理 | 加入 pendingCallbacks 取出 + MainActor.run 通知所有 callback nil |

### `liveAPP/PIPContent.swift` — populateVisibleMessagesIfNeeded 表情非同步載入

| 問題 | 原因 | 修正 |
|------|------|------|
| 表情圖片非同步載入完成後更新了 `inlineEmojiSizes[idx]`，但 emoji 的 `CALayer.frame` 已在 `layout(msg:)` 中以初始 `giftSize` 設定，不會重新計算 | `layout(msg:)` 只在訊息移動動畫期間被呼叫，動畫結束後不再重新排版；emoji frame 停留在初始大小 | 在載入 callback 中直接用 `CTLineGetOffsetForStringIndex` 計算 X 座標、`messageFrame.midY` 計算 Y 座標，立即設定 `emoji.frame = CGRect(x:baseX, y:emojiY, width:newSize.width, height:newSize.height)` |
| Task 未使用 capture list，closure 強捕獲 `msg` 與 `idx`，即使訊息已移除仍有 retain | 一般 closure 會強捕獲所有使用到的區域變數 | `Task { [idx, msg] in` 明確 capture；completion handler 使用 `[weak msg]` 避免延長訊息生命週期 |

### `liveAPP/PIPContent.swift` — layout(msg:) & 非同步 callback CTLine 文字取用

| 問題 | 原因 | 修正 |
|------|------|------|
| 所有 emoji 全部疊在同一 X 位置（`messageFrame.origin.x`） | `CATextLayer.string` 實際型別是 `NSAttributedString`（`buildMessageTuple` 以 `NSAttributedString(string:message, attributes:)` 設定），但 `layout(msg:)` 用 `as? NSString` 解讀 → 永遠回傳 `nil` → `text = ""` → `CTLine` 空的 → `CTLineGetOffsetForStringIndex` 對任何 index 都回傳 0 | 改為優先 `as? NSAttributedString` 取 `.string`，fallback `as? String` |

### 相關記憶體更新

- [memory #30](PROJECT_RULES) — 本次修復比對 log 發現 `UIImage(data:)` 失敗路徑完全無 callback 是結構性缺陷（不是單一的間歇性參數問題），符合「先追 pipeline 再下修」原則。

---

## 24. BroadcastButton 錯誤指向修正與日誌增強（2026-07）

### `liveAPP/ContentView.swift` — BroadcastButton.resolveExtension()

| 問題 | 原因 | 修正 |
|------|------|------|
| PlugIns 中有三個 extension（`ReplyKIT.appex`、`ReplyKITSetupUI.appex`、`ReplyKITNotification.appex`），`resolveExtension()` 直接回傳第一個找到的 `.appex`，可能選到 setup UI 或 notification extension | `FileManager.contentsOfDirectory` 不保證順序，回圈未過濾 extension type | 載入每個 `.appex` 的 `Info.plist`，檢查 `NSExtension.NSExtensionPointIdentifier` 是否為 `com.apple.broadcast-services-upload`，只回傳符合的 bundle ID |
| 無 PlugIns 目錄或無法讀取時無任何提示 | `try?` 吃掉所有錯誤 | 加入 `sendlog` 記錄失敗原因 |

### 日誌增強

| 位置 | 新增日誌 |
|------|----------|
| `resolveExtension()` | PlugIns 中 `appex` 總數；每個 extension 的檔名、bundle ID、類型（broadcast-upload/other）；最終選擇的 extension 及選取原因（PlugIns / user setting / constructed） |
| `makeUIView()` | `preferredExtension` 最終值、`Bundle.main.bundleIdentifier` |
| `updateUIView()` | 每次更新時記錄 extension |
| `buttonTapped` | 觸發時的 orientation 值 |
| `trigger()` | 呼叫記錄；`currentPicker` 為 nil 時記錄失敗；`UIButton` 找不到時記錄失敗 |
| `onChange(of: broadcastExtension)` | 使用者修改值時記錄 |

---

## 25. BGTaskScheduler 改用 BGAppRefreshTask（2026-07）

### `liveAPP/BackgroundTaskManager.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| `BGProcessingTask` 設計給長時間任務（資料庫清理、備份），系統優先級低，socket refresh 這類快速檢查常被延遲或跳過 | 選錯 task type，`BGProcessingTask` 的 ~5 分鐘預算對 2 秒工作而言過重 | 改為 `BGAppRefreshTaskRequest` + `BGAppRefreshTask`，系統優先級較高、適合短暫網路檢查 |
| 僅呼叫 `SocketServer.shared.start()` 不確認連線狀態 | handler 只管 listener 是否在跑，不驗證已建立的連線是否可用 | 加入 `server.sendKeepalive()`，同時對所有已連線 client 發送 keepalive 並清理 60 秒無資料的停滯連線 |
| 工作預算僅 2 秒，網路延遲時容易到期失敗 | `asyncAfter(deadline: .now() + 2)` 預留時間不足 | 延長至 10 秒，配合 `BGAppRefreshTask` 的 ~30 秒預算 |

### `liveAPP/Socket.swift` — sendKeepalive 可見度

| 問題 | 原因 | 修正 |
|------|------|------|
| `sendKeepalive()` 為 `private`，`BackgroundTaskManager` 無法呼叫 | 方法只在 keepalive timer 內部使用，未考慮外部觸發場景 | 改為 `internal`（移除 `private`），讓 `BackgroundTaskManager` 可在 BGTask handler 中主動調用 |

---

## 26. Live Activity 鎖定畫面／動態島即時串流資訊（2026-07）

### `liveAPP/LiveActivityAttributes.swift` — 新檔

| 元件 | 用途 |
|------|------|
| `StreamActivityAttributes` | ActivityKit 屬性定義：靜態（stream title）+ 動態狀態（碼率、時間、觀看人數） |
| `StreamActivityLiveView` | 鎖定畫面 UI：直播標題、時間、碼率、觀看人數 |
| `StreamActivityDynamicIsland` | 動態島：展開態顯示時間、碼率、人數；緊湊態顯示碼率 |
| `StreamActivityManager` | 生命週期管理：`startStreamActivity()` / `updateStreamActivity()` / `endStreamActivity()` + 每 5 秒自動更新 |

### `liveAPP/liveConfig.swift` — 新增欄位

| 欄位 | 型別 | 用途 |
|------|------|------|
| `streamBitrate` | `String` | 格式化碼率文字（如 `"2.4 Mbps"`），供 Live Activity 讀取 |

### `liveAPP/ContentView.swift` — BitrateManager

| 問題 | 原因 | 修正 |
|------|------|------|
| 碼率變更不會更新 Live Activity | `updateStreamBitrate()` 只存 UserDefaults + 發 Darwin notification | 加入 `LPConfig.shared.streamBitrate` 更新，Live Activity 自動定時讀取 |

### 使用方式

需在開播／停播處手動加入：

```swift
// 開播
StreamActivityManager.shared.startStreamActivity()

// 停播
StreamActivityManager.shared.endStreamActivity()
```

支援最低版本：iOS 16.1（與目前 Deployment Target 16.6 相容）。
