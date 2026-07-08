# PiP 性能優化 (2026-07)

## 概述

改善子母畫面（PiP）渲染管線的多項效能瓶頸：

- 移除不必要的 async hop（actor → Task → MainActor）
- 加入 dirty flag 避免無變化時仍每秒產生 pixel buffer
- 時間疊加層（overlay）加入快取，不再每幀重新計算 Core Text
- 消除配置（layout）重複計算

---

## 1. 移除 PIPRenderPipeline actor

### `liveAPP/PIPService.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| 每幀 3 次 async hop | timer → `Task { await actor.requestRender() }` → `actor.loop()` → `MainActor.renderIncremental()` | 直接 `Task { @MainActor in renderIncremental() }`，減少非同步切換開銷 |
| actor 無實際保護效果 | actor 不持有 mutable state，且 render 已由 `renderQueue` (serial) + `@MainActor` 保證序列化 | 移除 actor，render timer handler 直接呼叫 `renderIncremental()` |

## 2. Dirty flag 跳過無變化渲染

### `liveAPP/PIPService.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| idle 1 FPS 時仍每秒產 pixel buffer | render timer 固定間隔觸發，不問畫面是否變化 | 新增 `needsRedraw` flag：`addMessage()`／`requestAnimationFPS()`／`markOverlayDirty()` 設為 true，`renderIncremental()` 在 `!needsRedraw && !wasAnimating` 時直接 return |
| 時間疊加層久未更新 | 無變化時完全停止渲染，overlay 時間停留 | 每 30 秒強制一次 periodic redraw（`lastPeriodicRedraw`） |

### 資料流對比

```
改善前：
  timer(1Hz) → renderUIViewToPixelBuffer() → memset → CALayer.render() → drawTimeOverlay() → enqueue

改善後：
  timer(1Hz) → tickAnimation() → needsRedraw? → (false) → return  // 0 heavy work
  [新訊息] → setNeedsRedraw() → timer → tickAnimation() → needsRedraw? → (true) → render → enqueue
```

## 3. 時間疊加層快取

### `liveAPP/PIPService.swift`

| 問題 | 原因 | 修正 |
|------|------|------|
| overlay 每幀重新計算 Core Text | `drawTimeOverlay()` 每次都建立 NSAttributedString、計算 text size、繪製 badge | 快取 timeString / elapsedString / streamEnded / viewerCount / isReconnecting，只有值變化時才實際執行繪圖 |

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

## 檔案變更

| 檔案 | 行數變化 |
|------|----------|
| `liveAPP/PIPService.swift` | -46 (actor) +80 (dirty flag, overlay cache, periodic redraw) +22 (tiered memory, forceRender, isPiPActive) |
| `liveAPP/PIPContent.swift` | -1 (redundant layout) +1 (reloadPending guard) |
| `liveAPP/ContentView.swift` | ~30 (trimTextStorage → range deletion, remove CATransaction/layout duplication) |
| `liveAPP/liveAPPApp.swift` | ~5 (LogModel lazy trimming, memory warning 不強制清 logs) |
| `liveAPP/BackgroundTaskManager.swift` | +8 (PiP 活躍時跳過 bgTask/BGTaskScheduler) |
