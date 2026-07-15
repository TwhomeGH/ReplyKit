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
| 觸發 | 被動回應 server `keepalive`，或主動每 10s 由用戶端定時器發送 |
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
| 用戶端行為 | 收到後套用到 `RPConfig.shared`，通知 VideoReconfig |

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

## 連線模型

- 伺服端：`NWListener` 常駐監聽 port 9322
  - `keepalive` timer 每 **10s** 廣播 `{"type":"keepalive"}` 保活
  - 發送 keepalive 前檢查 `lastReceiveTime`，連線 >60s 無任何資料視為 dead 並移除
  - 用戶端 `heartbeat` 或任何資料都會更新 `lastReceiveTime`
- 用戶端：
  - 按需連線（on-demand），每次操作（requestRTMP、logConfig、UPSet、sendStreamEnd、flushBatch）獨立建立 TCP 連線，收到回應後關閉
  - 連線存活期間，**主動每 10s** 發送 `{"type":"heartbeat"}` 供 server 檢測健康度
  - 被動回應 server 的 `keepalive` 時也發送 `heartbeat`
- logbatch 在 `onLogPage=true` 時保持長連線，false 時關閉
