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

## 檔案變更

| 檔案 | 行數變化 |
|------|----------|
| `liveAPP/PIPService.swift` | -46 (actor) +80 (dirty flag, overlay cache, periodic redraw) +22 (tiered memory, forceRender, isPiPActive) ~40 (self-scheduling, renderCancelled, cooldown, FPS tune) |
| `liveAPP/PIPContent.swift` | -1 (redundant layout) +1 (reloadPending guard) |
| `liveAPP/ContentView.swift` | ~30 (trimTextStorage → range deletion, remove CATransaction/layout duplication) |
| `liveAPP/liveAPPApp.swift` | ~5 (LogModel lazy trimming, memory warning 不強制清 logs) |
| `liveAPP/BackgroundTaskManager.swift` | +8 (PiP 活躍時跳過 bgTask/BGTaskScheduler) |
