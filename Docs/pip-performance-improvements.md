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

## 9. SocketServer 保持常駐 + 輕量 memory release

### `liveAPP/Socket.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| 1 小時無連線後 server 自殺 | `startActivityIdleTimer(3600)` 在 `start()` 和 `removeConnection()` 最後連線移除時啟動 | 改為 no-op，`NWListener` 持續監聽，永不自動關閉 |
| Memory Warning 時清除 idle timers | `releaseMemory()` 將 per-connection idle timers 全部 cancel，導致連線遺失後無法自動清理 | 只清 send/receive buffer，保留 per-connection idle timers |
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

## 14. PiP 渲染優化（CPU 路徑）

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
