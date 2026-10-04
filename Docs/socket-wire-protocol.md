# E-Socket Wire Protocol

**Transport:** TCP, default port 9322 (configurable in the main app's Socket settings when App Group sharing is available)
**Format:** JSON, each message delimited by `0x0A` (newline)  
**Server:** `liveAPP/Socket.swift` — `SocketServer`  
**Client:** `ReplyKIT/Socket.swift` — `SocketClient`

---

## 連線設定

主 App「設定 → Socket 連線」顯示目前監聽狀態、實際端口及 Wi-Fi／有線網路 IPv4，並提供複製位址。
位址在頁面開啟、回到前景及網路變更時更新，也可手動重新整理。

自訂端口範圍為 1024–65535，預設 9322。新端口監聽就緒後才儲存設定並替換舊服務；占用或逾時會保留原有服務。
切換成功會中斷既有 Socket 連線，外部用戶端須改用新端口。ReplyKIT 的首次連線及重連會讀取 App Group 中的 `socketListenPort`。
直播或螢幕錄製期間不允許修改端口；恢復預設值會先填入 9322，按「套用」後才生效。
無 App Group 的安裝模式暫不開放自訂端口，主 App 與 ReplyKIT 都使用 9322。
端口被占用時停止自動重試，可在設定頁修改端口或按「重試啟動」。

### 裝置驗證

- 連接 Wi-Fi，確認列出的 IPv4 與系統設定一致，複製值含實際端口；切換網路及返回前景後確認更新。
- 輸入空白、0、1023、65536 或非數字時不可套用；1024 與 65535 可提交。
- 使用外部 TCP 用戶端連線，再切換至空閒端口，確認舊連線關閉、新端口可連線，重新啟動 App 後設定保留。
- 占用候選端口後套用，確認顯示占用錯誤、原端口仍可連線且儲存值未變。
- 重新啟動 ReplyKIT，確認首次連線、斷線重連及設定請求都使用新端口。
- 開始螢幕直播後確認端口控制項停用；停止後可套用。側載且無 App Group 時確認雙方仍使用 9322。

---

## 所有訊息類型

### `heartbeat` — 用戶端心跳

| 方向 | → Server |
| ------ | ---------- |
| Payload | `{"type":"heartbeat"}` |
| 觸發 | 僅被動回應 server 發送的 `keepalive`，用戶端不主動發送 |
| Server 行為 | 記錄「收到 Socket 心跳」及實際來源連線的物件 ID、遠端端點；接收資料時照常更新該連線的 `lastReceiveTime` |

心跳日誌格式：`收到 Socket 心跳｜連線=ObjectIdentifier(...)｜遠端=<位址>:<連接埠>`。
連線建立、就緒、失敗、取消及移除日誌使用相同識別格式，方便交叉追蹤。
識別資訊取自接收訊息的 `NWConnection`，不需修改 heartbeat payload。
物件 ID 僅在該物件存活期間唯一，歷史紀錄需搭配遠端端點及建立／移除時間判讀；遠端端點不是已驗證的使用者或裝置身分。

---

### `keepalive` — 伺服器保活

| 方向 | Server → |
| ------ | ---------- |
| Payload | `{"type":"keepalive"}` |
| 觸發 | 10 秒定時器，向所有連線廣播 |
| Server 行為 | 發送前檢查 `lastReceiveTime`，若該連線 >60 秒無任何資料視為 dead 並移除；防止 NWConnection 閒置超時自動斷線 |
| 用戶端行為 | 收到後回 `{"type":"heartbeat"}` 雙向重置 idle timer |

---

### `StreamStarting` — 直播開始

| 方向 | → Server |
| ------ | ---------- |
| Payload | `{"type":"StreamStarting"}` |
| Server 行為 | 記錄開始時間、重設觀眾人數與列表、標記 isLive |

---

### `Ended` — 直播結束

| 方向 | → Server |
| ------ | ---------- |
| Payload | `{"type":"Ended","Message":"StreamEnded"}` |
| Server 行為 | 呼叫 `StreamStatusChanged(isLive:false)` |

---

### `audience` — 純觀眾資訊更新

| 方向 | → Server |
| ------ | ---------- |
| Payload | `{"type":"audience","userNum":Int?,"userList":[String]?,"useTTS":Bool?}` |
| Server 行為 | 僅更新觀眾數量與列表，不渲染任何聊天訊息 |
| 用途 | 與 `StreamMessage` 分離，避免為了更新人數而傳送空字串聊天訊息 |

---

### `StreamMessage` — 聊天室訊息

| 方向 | → Server |
| ------ | ---------- |
| Payload | `{"type":"StreamMessage","user":String,"message":String,"img":String?,"giftImg":String?,"isMain":Bool?,"userNum":Int?,"userList":[String]?}` |
| Server 行為 | 更新觀眾資訊、PiP 疊加層渲染聊天訊息；useTTS 允許時交由 TTS 服務判斷朗讀 |

`useTTS` 為可選 JSON 布林值，省略或 `null` 時預設 `true`，相容既有發送端。`false` 只略過該則訊息的朗讀，不影響聊天顯示、觀眾資訊，也不停止正在朗讀的內容或清空既有佇列。`true` 仍受 App 的 TTS 總開關、主要訊息設定及文字篩選限制，不會強制啟用服務。字串 `"false"` 或數字不屬於合法值，會解碼失敗。

```json
{
  "type": "StreamMessage",
  "user": "userName",
  "message": "這則只顯示，不朗讀",
  "useTTS": false
}
```

**PiP 行內 emoji 渲染** — `message` 中的圖片 URL（`https://...png|jpg|gif|webp`）會自動提取並在聊天文字中行內顯示：

```text
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
| ------ | ---------- |
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

```log
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
| ------ | --- |
| Request | `{"type":"UPSet","key":String,"ValueType":"String"\|"Bool"\|"Double"\|"Int"\|"Float"}` |
| Response | `{"type":"UPSet","key":String,"value":<typed-value>}` |
| Server 行為 | 讀取指定 key 的值並回應，connection 用完即關 |

---

### `batch` — 批次請求

| 方向 | → Server |
| ------ | ---------- |
| Request | `{"type":"batch","requests":["requestRTMP","logConfig"]}` |
| Server 行為 | 依序處理 `requestRTMP` → `logConfig` → `{"type":"BatchEnded"}`，逐筆回應 |

---

### `BatchEnded` — 批次結束

| 方向 | Server → |
| ------ | ---------- |
| Payload | `{"type":"BatchEnded"}` |
| Server 行為 | 批次處理完成後附加的最後一筆回應 |
| 用戶端行為 | 收到後關閉連線 |

---

### `requestRTMP` / `RTMP` — 推流設定

| 方向 | ↔ |
| ------ | --- |
| Request | `{"type":"requestRTMP"}` |
| Response | `{"type":"RTMP","rtmpURL":String,"rtmpKey":String,"BitRate":Int,"dstW":Int,"dstH":Int,"odstW":Int,"odstH":Int,"Rotate":Int,"videoBuffer":Int,"useEnhancedRTMP":Bool?, ...}` |
| Server 行為 | 從 UserDefaults 讀取 RTMP 設定後回應 |
| 用戶端行為 | 收到後套用到 `RPConfig.shared`，由開播流程在 publish 前套用 video settings |

`dstW` / `dstH` 是 GPU 中間處理尺寸，`odstW` / `odstH` 是最終畫布與 encoder 輸出尺寸。完整設計見 [video-dimensions.md](video-dimensions.md)。

---

### `logConfig` — 日誌設定

| 方向 | ↔ |
| ------ | --- |
| Request | `{"type":"logConfig"}` |
| Response | `{"type":"logConfig","logMode":Int,"logURL":String,"onlogPage":Bool,"onAudioPage":Bool,"enableLog":Bool,"enableSocketLog":Bool,"enableTimeDebug":Bool,"enablePipelineLog":Bool}` |
| Server 行為 | 從 UserDefaults 讀取日誌設定後回應 |
| 用戶端行為 | 收到後套用 log mode、log URL |

---

### `audioLive` — 音量即時更新

| 方向 | → Server |
| ------ | ---------- |
| Payload | `{"type":"audioLive","appVol":Float,"micVol":Float,"persist":Bool}` |
| Server 行為 | 更新 `LiveVolumeModel` 中的麥克風與應用程式音量 |

---

### `videoHealth` — 視訊管線健康樣本

| 方向 | → Server |
| ------ | ---------- |
| Payload | `{"type":"videoHealth","status":String,"inputFPS":Double,"processedFPS":Double,"droppedFPS":Double,"timeoutDelta":Int}` |
| 觸發 | ReplayKit extension 每秒從 `SampleHandler` 彙整一次 |
| Server 行為 | 更新 `VideoHealthModel`，供設備信息頁圖表化顯示 |
| 實作 | Extension 端使用 `VideoHealthPayload: Codable` 產生 payload，Server 端 decode 為 `VideoHealthPayload` |

這是正式 telemetry 訊息，不應從 `[VHealth]` log 字串解析圖表資料。

`status` 目前可能值：

| 值 | 含義 |
| ---- | ------ |
| `healthy` | 輸入與處理 FPS 接近，沒有 Metal timeout |
| `upstream-throttle` | ReplayKit 上游擷取 FPS 偏低，通常是前景遊戲/GPU 排程壓制 |
| `metal-pressure` | Metal command buffer timeout 或 in-flight 壓力升高 |
| `processor-pressure` | input 正常但 processed 明顯落後 |
| `processor-drop` | 單秒內有處理 drop |

---

### `audioHealth` — 音訊管線健康樣本

| 方向 | → Server |
| ------ | ---------- |
| Payload | `{"type":"audioHealth","status":String,"appInputFPSMin/Avg/Max":Double,"micInputFPSMin/Avg/Max":Double,"appGapMaxMs":Double,"alignDroppedPerSec":Double,"alignInsertedPerSec":Double,"alignFirePerSec":Double,"alignDiffMaxSamples":Double,"skipInsertedPerSec":Double,"overflowDroppedPerSec":Double,"resampleNoDataPerSec":Double,"mixerOutputFPS":Double,"appRMS":Double,"micRMS":Double,"outChannels":Int,"outCh0RMS":Double,"outCh1RMS":Double}` |
| 觸發 | ReplayKit extension 每秒累積、每 5s 彙總送出（與 `videoHealth` 同節奏） |
| Server 行為 | 更新 `AudioHealthModel`，供設備信息頁「Audio Pipeline」圖表顯示 |
| 實作 | Extension 端 `SampleHandler.logAudioHealthIfNeeded` → `SocketClient.sendAudioHealth`；下游計數來自 HaishinKit `MediaMixer.audioPipelineDiagnostics()`（repo `TwhomeGH/HaishinKitFixSwfit`） |

`audioHealth` 是目前唯一能看到 **content-level 斷音** 的 telemetry：幀數（inputFPS）正常但 `alignDroppedPerSec` / `skipInsertedPerSec` / `resampleNoDataPerSec` 大於 0，代表 1024-sample 封包內部被丟樣本或補靜音。

`status` 目前可能值：

| 值 | 含義 |
| ---- | ------ |
| `healthy` | app/mic inputFPS 正常，無 align drop / underrun / 大 gap |
| `input-idle` | app 與 mic 都幾乎沒有輸入幀 |
| `align-churn` | `align()` 幾乎每秒都在動手（alignFirePerSec 高）— 代表持續對非 main track 做硬丟/硬補，是 content-level 斷音的典型訊號 |
| `align-drop` | `AudioRingBuffer.align()` 丟棄了非 main track 的樣本（雙軌 PTS 未對齊） |
| `buffer-overflow` | ring buffer 溢位丟樣本（producer 超出 consumer） |
| `underrun` | `resample()` 有 append 完全沒產出（ring buffer 來不及給完整塊） |
| `source-gap` | PTS 缺口導致 `skip` 補靜音，或幀間 PTS gap > 100ms |

---

### `settings` — 設定同步

| 方向 | → Server |
| ------ | ---------- |
| Payload | `{"type":"settings","key":String,"value":<JSON-value>}` |
| Server 行為 | 寫入 `UserDefaults.standard`，音量相關 key 發送 Darwin notification |
| 備註 | Server 也可廣播給用戶端，但用戶端無對應 handler (silently dropped) |

---

### `log` — 單條日誌

| 方向 | ↔ |
| ------ | --- |
| → Server | `{"type":"log","title":String,"message":String}` |
| → Client | `{"type":"log","message":String}` |
| Server 行為 | 寫入 LogBuffer 與 AppLogPersister |
| 用戶端行為 | 收到後僅本地記錄 `[Extension] Get ...` |

---

### `logbatch` — 批量日誌

| 方向 | → Server |
| ------ | ---------- |
| Payload | `{"type":"logbatch","entries":[String]}` |
| Server 行為 | 每條 entry 前綴 `UseESocket:` 後寫入 LogBuffer |
| 觸發 | 用戶端累積 ≥50 條或 ≥4KB 時打包送出，250ms 定時器確保殘餘 flush |

---

### `diagnostic` — 帶外診斷（log I/O 失敗）

| 方向 | ↔（extension → Server → 其他連線；Server 亦可自行發起） |
| ------ | ---------- |
| Payload | `{"type":"diagnostic","subsystem":"logio","source":"extension"\|"mainapp","count":Int,"lastError":String}` |
| 觸發 | 日誌檔寫入失敗時累積計數，**每 60 秒最多送出一則有界摘要** |
| Server 行為 | `broadcast(dict, excluding: 來源連線)`：群播給**其他**所有連線（含外部工具），**不寫入 log 檔、不寫 AppLogPersister** |
| 外部工具 | 可接收此類訊息；未知 `type` 應忽略（勿因無法解析而斷線） |

設計要點：

- **帶外**：診斷不進 log 管線（`sendlog` / `early-log` / `append`），避免「寫入失敗→記診斷→又寫檔」的回饋迴圈。
- **有界**：只送摘要（`count` + `lastError`），不逐筆，防止灌爆 socket 與外部分析工具。
- **OSLog 兜底**：無論 socket 是否連通，失敗一律以 `os_log` / `logger.debug` 記錄；socket 只是「有連線才有」的即時外部通道（extension 的 OSLog 需靠 sysdiagnose 取得）。
- Server 自身（主 App `AppLogPersister`）的 `logio` 失敗由 `SocketServer.shared.broadcastDiagnostic([...])` 發起，`source` 為 `mainapp`；extension 則由 `SocketClient.shared.sendPayload([...])` 送出，`source` 為 `extension`。
- Payload 為一般 `[String: Any]`（非 `Codable` 結構），但必須含頂層 `type` 欄位，否則 `handleReceivedData` 解碼失敗會直接關閉該連線。

---

### `reconnectStatus` — RTMP 重連狀態

| 方向 | → Server |
| ------ | ---------- |
| Payload | `{"type":"reconnectStatus","status":"attempting"\|"success"\|"failed"\|"exhausted","attempt":Int}` |
| Server 行為 | 只有 `attempt > 0` 的 `attempting` / `failed` 會更新 PiP overlay 的 reconnecting 狀態顯示；`attempt = 0`、`success`、`exhausted` 會清空重連狀態 |

#### `attempt = 0` 防殘留規則

`attempt = 0` 不代表「第 0 次重連中」，只表示 RTMP 狀態機尚未進入有效重連次數，或正在回復到正常狀態。主 App 收到 `attempting 0` / `failed 0` 時必須清掉 `LPConfig.shared.isReconnecting` 與 `LPConfig.shared.reconnectStatus`，避免 PiP / Live Activity 顯示 `0/5` 後誤判為斷線並卡住。

Broadcast Extension 端也不應在初始 `publish` 失敗時直接送出 `failed 0`；需等 HaishinKit 的 reconnect callback 回報 `.started(attempt > 0)` 後，才把後續 `failed` 視為可顯示的重連狀態。

---

### `testRTMP` — 偵錯廣播

| 方向 | Server → |
| ------ | ---------- |
| Payload | `{"type":"testRTMP","key":"test3","value":"OK"}` |
| 用途 | 從 Setting.swift 廣播給用戶端，用戶端收到後觸發 requestRTMP + logConfig 測試 |

---

## 資料流向總覽

```text
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
  diagnostic ────────────►                   群播給其他連線（不寫檔）

                           ◄─── keepalive (10s 定時廣播，含 stale 連線清理)
                           ◄─── testRTMP (偵錯)
                           ◄─── diagnostic (log I/O 失敗摘要，群播至外部工具)
```

## 結構定義

| 結構體 | 所在檔案 | 用途 |
| -------- | ---------- | ------ |
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
| ------ | ----- | ------ |
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
