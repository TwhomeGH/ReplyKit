# E-Socket Wire Protocol

**Transport:** TCP, port 9322  
**Format:** JSON, each message delimited by `0x0A` (newline)  
**Server:** `liveAPP/Socket.swift` — `SocketServer`  
**Client:** `ReplyKIT/Socket.swift` — `SocketClient`

---

## 所有訊息類型

### `heartbeat` — 用戶端心跳

| 方向 | → Server |
|------|----------|
| Payload | `{"type":"heartbeat"}` |
| 觸發 | 僅被動回應 server 發送的 `keepalive`，用戶端不主動發送 |
| Server 行為 | 僅記錄「收到Socket心跳維持連線」，同時更新該連線的 `lastReceiveTime` |

---

### `keepalive` — 伺服器保活

| 方向 | Server → |
|------|----------|
| Payload | `{"type":"keepalive"}` |
| 觸發 | 10 秒定時器，向所有連線廣播 |
| Server 行為 | 發送前檢查 `lastReceiveTime`，若該連線 >60 秒無任何資料視為 dead 並移除；防止 NWConnection 閒置超時自動斷線 |
| 用戶端行為 | 收到後回 `{"type":"heartbeat"}` 雙向重置 idle timer |

---

### `StreamStarting` — 直播開始

| 方向 | → Server |
|------|----------|
| Payload | `{"type":"StreamStarting"}` |
| Server 行為 | 記錄開始時間、重設觀眾人數與列表、標記 isLive |

---

### `Ended` — 直播結束

| 方向 | → Server |
|------|----------|
| Payload | `{"type":"Ended","Message":"StreamEnded"}` |
| Server 行為 | 呼叫 `StreamStatusChanged(isLive:false)` |

---

### `audience` — 純觀眾資訊更新

| 方向 | → Server |
|------|----------|
| Payload | `{"type":"audience","userNum":Int?,"userList":[String]?}` |
| Server 行為 | 僅更新觀眾數量與列表，不渲染任何聊天訊息 |
| 用途 | 與 `StreamMessage` 分離，避免為了更新人數而傳送空字串聊天訊息 |

---

### `StreamMessage` — 聊天室訊息

| 方向 | → Server |
|------|----------|
| Payload | `{"type":"StreamMessage","user":String,"message":String,"img":String?,"giftImg":String?,"isMain":Bool?,"userNum":Int?,"userList":[String]?}` |
| Server 行為 | 更新觀眾資訊、PiP 疊加層渲染聊天訊息、TTS 朗讀 |

**PiP 行內 emoji 渲染** — `message` 中的圖片 URL（`https://...png|jpg|gif|webp`）會自動提取並在聊天文字中行內顯示：

```
┌──────────────────────────────┐
│  user: 你好 🖼️ 謝謝          │   ← emoji 顯示在 URL 原本位置
│  user: 另一則訊息 🖼️ 🖼️     │       換行時正確跟隨所屬行
└──────────────────────────────┘
```

- 表情圖片位置使用 CoreText `CTLineGetOffsetForStringIndex` 精準對應到文字中 URL 原始字元位置
- 垂直基準線與該行文字 `ascent` 對齊，非 frame 置中
- 支援多個 emoji、多行文字，換行後 emoji 自動歸屬正確行

---

### `AdOverlay` — 廣告贊助訊息

| 方向 | → Server |
|------|----------|
| Payload | `{"type":"AdOverlay","user":String?,"text":String,"iconURL":String?,"useTTS":Bool}` |
| Server 行為 | 系統通知（可選）+ TTS 朗讀（可選）+ **PiP 贊助橫幅疊層** |

```json
{
  "type": "AdOverlay",
  "user": "贊助者名稱",
  "text": "贊助訊息內容",
  "iconURL": "https://example.com/avatar.png",
  "useTTS": true
}
```

**PiP 贊助橫幅疊層**（`liveAPP/PIPService.swift` — `addAdOverlay`）：

```
┌──────────────────────┐
│ ┌──────────────────┐ │
│ │ ⭐ 贊助者名稱    │ │ ← 金底圓角橫幅，y=4, h=52
│ │   贊助訊息內容   │ │    5 秒自動淡出，可選頭像圖示
│ └──────────────────┘ │
│    聊天訊息往上滾動   │
└──────────────────────┘
```

- 渲染層級：顯示在聊天訊息之上、時間疊層之上（最上層）
- 位置：PiP 頂部 `y=4`，橫幅高 `52pt`，寬度 `88%`
- 視覺：金底 `rgba(0.9, 0.55, 0.05, 0.88)`、圓角 `10`、白色粗體名稱 + 灰色內文
- 持續時間：5 秒後自動清除，最後 0.5 秒 alpha 淡出
- 頭像：非同步透過 `PiPImageCache` 下載，圓形裁切；無 URL 時顯示 `star.fill` 系統圖示
- PiP 關閉或收到記憶體警告時立即清除

---

### `UPSet` — 讀取 UserDefaults

| 方向 | ↔ |
|------|---|
| Request | `{"type":"UPSet","key":String,"ValueType":"String"|"Bool"|"Double"|"Int"|"Float"}` |
| Response | `{"type":"UPSet","key":String,"value":<typed-value>}` |
| Server 行為 | 讀取指定 key 的值並回應，connection 用完即關 |

---

### `batch` — 批次請求

| 方向 | → Server |
|------|----------|
| Request | `{"type":"batch","requests":["requestRTMP","logConfig"]}` |
| Server 行為 | 依序處理 `requestRTMP` → `logConfig` → `{"type":"BatchEnded"}`，逐筆回應 |

---

### `BatchEnded` — 批次結束

| 方向 | Server → |
|------|----------|
| Payload | `{"type":"BatchEnded"}` |
| Server 行為 | 批次處理完成後附加的最後一筆回應 |
| 用戶端行為 | 收到後關閉連線 |

---

### `requestRTMP` / `RTMP` — 推流設定

| 方向 | ↔ |
|------|---|
| Request | `{"type":"requestRTMP"}` |
| Response | `{"type":"RTMP","rtmpURL":String,"rtmpKey":String,"BitRate":Int,"dstW":Int,"dstH":Int,"odstW":Int,"odstH":Int,"Rotate":Int,"videoBuffer":Int,"useEnhancedRTMP":Bool?, ...}` |
| Server 行為 | 從 UserDefaults 讀取 RTMP 設定後回應 |
| 用戶端行為 | 收到後套用到 `RPConfig.shared`，由開播流程在 publish 前套用 video settings |

`dstW` / `dstH` 是 GPU 中間處理尺寸，`odstW` / `odstH` 是最終畫布與 encoder 輸出尺寸。完整設計見 [video-dimensions.md](video-dimensions.md)。

---

### `logConfig` — 日誌設定

| 方向 | ↔ |
|------|---|
| Request | `{"type":"logConfig"}` |
| Response | `{"type":"logConfig","logMode":Int,"logURL":String,"onlogPage":Bool,"onAudioPage":Bool,"enableLog":Bool,"enableSocketLog":Bool,"enableTimeDebug":Bool,"enablePipelineLog":Bool}` |
| Server 行為 | 從 UserDefaults 讀取日誌設定後回應 |
| 用戶端行為 | 收到後套用 log mode、log URL |

---

### `audioLive` — 音量即時更新

| 方向 | → Server |
|------|----------|
| Payload | `{"type":"audioLive","appVol":Float,"micVol":Float,"persist":Bool}` |
| Server 行為 | 更新 `LiveVolumeModel` 中的麥克風與應用程式音量 |

---

### `videoHealth` — 視訊管線健康樣本

| 方向 | → Server |
|------|----------|
| Payload | `{"type":"videoHealth","status":String,"inputFPS":Double,"processedFPS":Double,"droppedFPS":Double,"timeoutDelta":Int}` |
| 觸發 | ReplayKit extension 每秒從 `SampleHandler` 彙整一次 |
| Server 行為 | 更新 `VideoHealthModel`，供設備信息頁圖表化顯示 |
| 實作 | Extension 端使用 `VideoHealthPayload: Codable` 產生 payload，Server 端 decode 為 `VideoHealthPayload` |

這是正式 telemetry 訊息，不應從 `[VHealth]` log 字串解析圖表資料。

`status` 目前可能值：

| 值 | 含義 |
|----|------|
| `healthy` | 輸入與處理 FPS 接近，沒有 Metal timeout |
| `upstream-throttle` | ReplayKit 上游擷取 FPS 偏低，通常是前景遊戲/GPU 排程壓制 |
| `metal-pressure` | Metal command buffer timeout 或 in-flight 壓力升高 |
| `processor-pressure` | input 正常但 processed 明顯落後 |
| `processor-drop` | 單秒內有處理 drop |

---

### `settings` — 設定同步

| 方向 | → Server |
|------|----------|
| Payload | `{"type":"settings","key":String,"value":<JSON-value>}` |
| Server 行為 | 寫入 `UserDefaults.standard`，音量相關 key 發送 Darwin notification |
| 備註 | Server 也可廣播給用戶端，但用戶端無對應 handler (silently dropped) |

---

### `log` — 單條日誌

| 方向 | ↔ |
|------|---|
| → Server | `{"type":"log","title":String,"message":String}` |
| → Client | `{"type":"log","message":String}` |
| Server 行為 | 寫入 LogBuffer 與 AppLogPersister |
| 用戶端行為 | 收到後僅本地記錄 `[Extension] Get ...` |

---

### `logbatch` — 批量日誌

| 方向 | → Server |
|------|----------|
| Payload | `{"type":"logbatch","entries":[String]}` |
| Server 行為 | 每條 entry 前綴 `UseESocket:` 後寫入 LogBuffer |
| 觸發 | 用戶端累積 ≥50 條或 ≥4KB 時打包送出，250ms 定時器確保殘餘 flush |

---

### `reconnectStatus` — RTMP 重連狀態

| 方向 | → Server |
|------|----------|
| Payload | `{"type":"reconnectStatus","status":"attempting"|"success"|"failed"|"exhausted","attempt":Int}` |
| Server 行為 | 更新 PiP overlay 的 reconnecting 狀態顯示 |

---

### `testRTMP` — 偵錯廣播

| 方向 | Server → |
|------|----------|
| Payload | `{"type":"testRTMP","key":"test3","value":"OK"}` |
| 用途 | 從 Setting.swift 廣播給用戶端，用戶端收到後觸發 requestRTMP + logConfig 測試 |

---

## 資料流向總覽

```
ReplyKIT (Extension)                          liveAPP (Main App)
────────────────────                          ──────────────────
  heartbeat ──────────────►                   更新 lastReceiveTime (10s 定時)
  audience ───────────────►                   僅更新觀眾人數/列表
  StreamStarting ────────►                   reset 直播狀態
  Ended ─────────────────►                   終止直播
  StreamMessage ─────────►                   PiP 渲染 + TTS
  AdOverlay ─────────────►                   PiP 贊助橫幅 + TTS + 通知
  UPSet ─────────────────►                   讀 UserDefaults 並回應
                          ◄─── UPSet 回應
  batch ─────────────────►                   requestRTMP + logConfig
                          ◄─── RTMP 設定
                          ◄─── logConfig
                          ◄─── BatchEnded
  audioLive ─────────────►                   更新音量
  settings ──────────────►                   寫 UserDefaults
  log / logbatch ────────►                   寫 LogBuffer
  reconnectStatus ───────►                   更新 PiP 重連 UI

                          ◄─── keepalive (10s 定時廣播，含 stale 連線清理)
                          ◄─── testRTMP (偵錯)
```

## 結構定義

| 結構體 | 所在檔案 | 用途 |
|--------|----------|------|
| `TypePayload` | `liveAPP/Socket.swift` | 每則訊息的 type 欄位 |
| `StreamEnded` | 同上 | Ended payload |
| `ChatMessage` | 同上 | StreamMessage payload |
| `UPSet` | 同上 | UPSet payload |
| `BatchRequest` | 同上 | batch payload |
| `AudioLive` | 同上 | audioLive payload |
| `SLogMessage` | 同上 | log payload |
| `LogBatchPayload` | 同上 | logbatch payload |
| `RTMPConfig` | `ReplyKIT/Socket.swift` | RTMP 回應 |
| `LogConfig` | 同上 | logConfig 回應 |
| `LogMessage` | 同上 | log 回應 |
| `AdOverlay` | `liveAPP/Socket.swift` | AdOverlay payload |
| `AudiencePayload` | 同上 | audience payload |

## 連線模型

- 伺服端：`NWListener` 常駐監聽 port 9322
  - `keepalive` timer 首次 **10s** 下次 每 **40s** 廣播 `{"type":"keepalive"}` 保活
  - 發送 keepalive 前檢查 `lastReceiveTime`，連線 >60s 無任何資料視為 dead 並移除
  - 用戶端 `heartbeat` 或任何資料都會更新 `lastReceiveTime`
- 用戶端：
  - 按需連線（on-demand），每次操作（requestRTMP、logConfig、UPSet、sendStreamEnd、flushBatch）獨立建立 TCP 連線，收到回應後關閉
  - **不主動發送 heartbeat**，僅被動回應 server 的 `keepalive` 時回送 `{"type":"heartbeat"}`
- logbatch 在 `onLogPage=true` 時保持長連線，false 時關閉

---

## 接收緩衝與 Framing Resync

兩端接收路徑共用相同的緩衝策略，用於在 `0x0A` framing 失步時復原連線。

### 緩衝行為

- 每個連線各自維護一個 receive buffer（`SocketClient.receiveBuffer` / `SocketServer.receiveBuffers[id]`）
- 每次 receive callback 收到資料後，立即同步**抽乾所有完整行**（以 `0x0A` 分隔）逐一解析
- 因此 buffer 在一般情況下只會剩下「尚未 trim 的已消費前綴」與「最後一個還沒等到換行的殘行」
- 殘行 trim 條件：`receiveOffset > buffer.count / 2` 時移除已消費前綴（amortized O(1)）

### 上限與觸發條件

| 常量 | 值 | 位置 |
|------|-----|------|
| `SocketClient.maxBufferSize` | 1,048,576 (1MB) | `ReplyKIT/Socket.swift` |
| `SocketServer.maxBufferSize` | 1,048,576 (1MB) | `liveAPP/Socket.swift` |

因為完整行每次 receive 都會被抽乾，`buffer.count > 1MB` 只在一種情況成立：**累積 1MB 資料內都未出現換行**——即單筆訊息超過 1MB，或對方 framing 失步／灌入無換行垃圾。

> 常規訊息（logConfig、RTMP、keepalive、pushState、UPSet、log batch）皆遠小於 1MB（log batch 另有 4KB 上限），故此上限是**異常 framing 的安全網，而非吞吐限制**，不建議調高——調高只會讓失步時的垃圾多累積數 MB 才觸發 resync。

### 超限處置：Resync 優先，斷線為最後手段

```swift
if buffer.count > maxBufferSize {
    if let newlineIndex = buffer[offset...].firstIndex(of: 0x0A) {
        // 丟棄「過大的那一行」+ 已消費前綴，從換行後繼續 → framing 復原，保持連線
        buffer.removeSubrange(0..<(newlineIndex + 1))
        offset = 0
        log("Buffer exceeded, dropped oversized line and resynced")
    } else {
        // 連換行都找不到 = 協議徹底失步 → 關閉連線
        closeConnection()
    }
}
```

- **找得到換行** → 丟棄那條過大的訊息與已消費前綴，重設 offset，**保持連線**並繼續解析後續正常訊息（resync）
- **找不到換行** → 對方在灌無換行垃圾或 framing 永久損壞，此時才關閉連線

### 改進動機

先前行為是 buffer 超限即關閉連線。這把「單一異常／過大的訊息」放大成「整個 log pipeline 中斷 + 重連」（sideload 下還需靠 `liveAPP.SocketRestart` Darwin notification 重建）。現行 resync 讓大部分失步案例只丟棄一筆異常資料即可復原，斷線僅保留給 framing 無法復原的最壞情況。
