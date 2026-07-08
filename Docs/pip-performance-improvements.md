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

## 4. 消除重複 layout 計算

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
| `liveAPP/PIPService.swift` | -46 (actor) +80 (dirty flag, overlay cache, periodic redraw) |
| `liveAPP/PIPContent.swift` | -1 (redundant layout) +1 (reloadPending guard) |
