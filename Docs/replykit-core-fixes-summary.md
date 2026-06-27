# ReplyKit 核心修正與性能改進

## 1. Socket 日誌傳輸管線重構（滑動視窗批次傳輸）

### 問題
每 1 秒 `flushLocalLogs()` 把整個 buffer `joined()` 成一個巨大字串 → 單次 payload 可能數百 KB → 8KB chunking 產生 N 個 `{"type":"log"}` 排進 serial queue → 最後的 chunk 等幾十秒 → 30s watchdog 砍連線。

### 修正
- **Ring buffer**（`Event.swift`）：`[String]` 改用固定 1000 條上限，超過自動 `removeFirst(excess)` 批次丟棄最舊，移除 byte 級追蹤
- **Batch send**（`ReplyKIT/Socket.swift`）：累積 entries，每 50 條或 4KB 打包成 `{"type":"logbatch","entries":[...]}` 一次送出，250ms 定時器確保殘餘 flush
- **Bounded window**：最多 3 個 in-flight batch，滿了自動 drop 最舊 batch
- **Server handler**（`liveAPP/Socket.swift`）：新增 `case "logbatch"` 解包逐條餵給 `receiveSocketLog`

### 預期改善
| 場景 | 改前 | 改後 |
|------|------|------|
| 大量 log burst | buffer 衝到 100KB → joined 送出 → socket timeout → 斷線重連 loop | ring buffer 自動 drop 最舊，batch ≤4KB，window 滿就 drop，連線穩定 |
| 連線中斷恢復 | pendingLogs 全部 replay（再次塞車） | pendingBatchEntries 暫存，reconnect 後 flush，單批 ≤4KB |

---

## 2. GPU 旋轉管線修復（GPUVideoRotator）

### 問題
- `gpuSemaphore`（AsyncSemaphore value:5）**完全未使用**：`wait()` 從未呼叫、`signal()` 被註解掉 → GPU 背壓形同虛設
- `NGPUSemaphore`（DispatchSemaphore value:10）**死碼**：從未使用
- `asyncWait()` helper 僅為 `NGPUSemaphore` 存在 → 死碼

### 修正
- `gpuSemaphore` 改為 **value: 3**（更合理），`wait()` 在 `rotateAsync` 開頭、`signal()` 在 GPU completion handler 中啟用
- 移除 `NGPUSemaphore` 與 `asyncWait()`

### 預期改善
- **GPU 不再強制串行**：改前 GPU 一次只能處理 1 幀（CPU 等 GPU→GPU 等 CPU），改後最多 3 幀 pipeline 執行
- **GPU 使用率提升**：CPU 準備 frame N+1 時 GPU 同時處理 frame N
- **60fps 更穩定**：減少因等待造成的掉幀

```
改前: CPU prepare → GPU rotate → CPU prepare → GPU rotate → ... (一次1幀)
改後: CPU prepare → GPU rotate (frame N)
         → CPU prepare → GPU rotate (frame N+1) ← 最多3幀飛行
```

---

## 3. VideoProcessor Watchdog（GPU 逾時自動重置）

### 問題
GPU 旋轉卡死時（驅動錯誤、Metal 內部 hang），`isProcessing = true` 永遠不會被釋放 → 後續所有 frame 被丟棄 → **直播斷流**。

### 修正
- 2 秒逾時檢測：`processingStartedAt` 記錄開始時間，下一幀抵達時檢查
- 逾時自動重置：`processorActor = nil` → 下一幀重新建立完整管線
- `processorActor` 改為 optional，看門狗可安全重建

### 預期改善
- **GPU hang 復原時間**：從「永久卡死」縮短到 **2 秒內自動恢復**
- **直播不中斷**：短暫掉 2-3 秒畫面後恢復正常推流

---

## 4. AppLogPersister 日誌檔 I/O 爆炸與無限制增長

### 問題
`liveAPPApp.swift:112-173` 存在**兩層問題**：

**第一層（容量）**：僅不斷 append，完全沒有限制 → 日誌檔隨時間無限增大。

**第二層（效能，更嚴重）**：初始修正加入 `trimLogFileIfNeeded()` 後，**每一行 log 寫入都觸發全檔讀取 + 分割 + 可能全檔寫回**：

```
append("hello") → write() → trimLogFileIfNeeded()
  → FileHandle.readToEnd() (讀完整個 5000 行檔案)
  → content.split(separator: "\n")
  → lines.count > 5000? 是 → suffix(5000) → 寫回完整檔案
```

重複此流程的次數等於日誌寫入次數。100 lines/sec 下，這等於 **100 次/秒完整讀寫 ~500KB 檔案**。serial queue 上的 I/O 積壓可能導致：
- **App 被 watchdog 判定主執行緒 hang → 強制終止 → 直播斷流**
- **寫入延遲疊加 → 寫一行 log 要數百毫秒完成**

### 修正
- **記憶體行數計數器**：`estimatedLineCount` 追蹤檔案行數，**不讀檔不 trim**
- **寬容閾值**：超過 `5000 + 2000`（即 7000 行）才安排 trim，減少 trim 頻率
- **Debounce 延遲**：超過閾值後延遲 **1 秒**才執行 trim，同批 burst 只觸發一次
- **trim 後更新計數器**：避免下次 trim 又全檔讀取

### 預期改善
| 場景 | 改前 | 改後 |
|------|------|------|
| 一般寫入（99.9% 情況） | 每行都全檔讀寫 | O(1) append only，trim 不執行 |
| 超過 7000 行時 | 每行都 trim（可能持續數百次） | 1 秒內只 trim 一次，回到 5000 行 |
| 大 burst（數千行瞬間湧入） | 數千次全檔讀寫，App 可能被 watchdog 殺 | 一次 trim + 安全邊界

---

## 6. 設備資訊頁 — 磁碟 I/O 圖表

### 新增
`DeviceView`（`OtherView.swift`）新增「磁碟 I/O」圖表與文字顯示，包含三個指標：

| 指標 | 來源 | 顏色 |
|------|------|------|
| **Page In**（換頁讀取） | `vm_statistics64.pageins` × page size | 🔵 藍 |
| **Page Out**（換頁寫出） | `vm_statistics64.pageouts` × page size | 🔴 紅 |
| **App Write**（日誌寫入） | `AppLogPersister.totalWrittenBytes` 差值 | 🟢 綠 |

- 每 1 秒取樣，`SystemDiskIO` 計算差值 → KB/s
- 使用 `LineMark` 三線疊合圖表呈現過去 60 秒的 I/O 流量
- 圖表下方附加最新值文字

### 用途
- Page In/Out 反映**系統記憶體壓力**（swap 活動量）
- App Write 反映**本 App 日誌寫入量**
- 可直觀判斷 watchdog kill 是否與大量檔案 I/O 或系統 swap 相關

### 儲存空間 - 可用 vs 空閒

iOS 的 `FileManager` 提供兩種容量查詢：

| API | 標籤 | 含義 |
|-----|------|------|
| `.systemAvailableSize` | 可用（含可清除） | 系統顯示的「可用空間」= 真正空閒 + 可 purge 的快取（iCloud、暫存檔等） |
| `.systemFreeSize` | 空閒（真正） | 純粹未使用的磁區空間，不包含可自動清除的資料 |

原始碼之前誤用了 `.systemFreeSize` 並標為「可用」，導致比裝置設定顯示的數字少一大截。修正後**兩者並列**，方便比對。差距大代表系統快取正在佔用可觀空間。

---

## 5. RemoteLogBuffer 爆量丟棄優化

### 問題
`RemoteLogBuffer.append` 使用 `removeFirst()` 逐條移除 → 大量 burst 時 N 次陣列 shift + N 次 `sendlog` 警告 → 日誌中數百條連續警告反而**加重 socket 負擔**。

### 修正
- 先 `append`，超過上限後一次 `removeFirst(excess)` 移除全部超額
- 只 log 一次警告

### 預期改善
- **爆量時不再觸發數百條警告迴圈**
- **陣列只 shift 一次**，CPU 開銷從 O(n) 降到 O(1)（amortized）

---

## 整體性能預期

| 指標 | 改前 | 改後 |
|------|------|------|
| Socket 連線穩定性 | burst log → timeout → 斷線重連 loop | batch 限流，連線保持不斷 |
| GPU 使用率 | ~30-40%（串行等待） | ~60-80%（3 幀 pipeline） |
| GPU hang 復原 | 永久卡死 | ≤2 秒自動重置 |
| 日誌檔大小 | 無限增長 | ≤~7000 行（trim 後回 5000） |
| Log burst 時 CPU（陣列層） | O(n) 逐條 shift + N 次 sendlog | O(1) amortized + 1 次 sendlog |
| AppLogPersister 寫入開銷 | 每筆寫入都全檔讀寫（O(N)） | O(1) append only，trim debounce 1s |
| 檔案 I/O 導致的 watchdog kill | 高風險（大量 log 時累積延遲） | 低風險（無 trim 時等同 0 I/O） |
