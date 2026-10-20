# 設備資訊：來源管線、網路流量與報告單位

## 兩種來源的共同入口

設備資訊的 Video Pipeline／Audio Pipeline 卡片讀取 `StreamDiagnosticsModel`，同時支援 ReplayKit 與 ScreenCaptureKit。

- ReplayKit：擴展每五秒透過 Socket 傳送 `StreamDiagnosticsSnapshot`。
- ScreenCaptureKit：每五秒直接更新同一模型；推流與本地可控錄製共用 Mixer 探針，推流停止而錄製繼續時仍回報。
- 系統直接錄製（SCRecordingOutput）未經 Mixer，不提供這組 Mixer 指標。畫面可能保留前次擷取的最後快照，應查看取樣狀態與時間。
- ReplayKit 原本的來源、丟幀、佇列等詳細資料保留在「ReplayKit 影片／音訊進階診斷」，不能當作 ScreenCaptureKit 的資料。

### 可選快照欄位

| 欄位 | 意義 |
| --- | --- |
| `mixerVideoFrames` | Mixer 已交付影格累計，編碼前 |
| `mixerAudioBuffers` | 混音 PCM buffer 累計，不是 AAC 封包 |
| `mixerAudioFrames` | PCM sample frames 累計，不乘聲道數 |
| `sampledUptime` | 同一 session 的單調時鐘取樣秒數 |
| `encoding` | 可選 RTMPEncodingDiagnostics，實際壓縮格式與輸出活動 |

`schemaVersion` 維持 1，舊端未提供時解碼為 nil。速率使用相鄰快照差分，每來源最多 60 筆。首次取樣、session 改變、計數倒退、間隔超過 15 秒均不推算速率；缺值不補零。停止後保留最後資料，不繼續追加假樣本。

影片 FPS 是混合輸出速率；PCM sample frames/s 是交付速率，與格式宣告的取樣率不同。這些都不代表 RTMP 已傳送或伺服器成功解碼。

### 實際編碼格式入口

Mixer 的 BGRA 是編碼前 RGB 像素排列，其格式不區分 YUV Full／Video，YCbCr matrix 對這個 RGB buffer 不適用。缺少 primaries／transfer 附件時保留「未提供」，不能推定為 BT.709 或 HDR，也不能推斷編碼後的色彩範圍。

使用 `await stream.encodingDiagnostics()` 取得值型別快照。底層從壓縮樣本更新，不以設定值或文字日誌代替。首次樣本與格式改變時讀取格式附件；後續只更新計數與最近輸出時間，不保留媒體 buffer。

影片提供 codec、寬高、可選色彩附件／Full Range；H.264 有 avcC 時顯示如 `avc1.64002A` 的實際設定識別碼。音訊提供 codec、Hz、聲道與每封包 sample frames。沒有附件保留未知，不能推定 BT.709。

session 為 RTMPStream 實例，generation 為發布工作世代。重連、停止、重建管線時清空；格式 revision 只是觀測到的格式變更次數，不是硬體編碼器 session ID。格式未變也持續更新最近輸出時間，兩個時間在設備頁分開顯示。

影片樣本／音訊 packet 與 payload bytes 在 RTMP 封裝前計數，不表示已入列或送達。停止後 App 保留最後快照，欄位標示「取樣時」狀態。系統直接錄製／純本地 Mixer 沒有 RTMP 快照，仍為 nil。

依賴底層 revision `7ce4304bed640df2335b312f449405b5f1d4e254`；使用者於 2026-10-20 確認底層前置工作完成，主 App 已鎖定此版本。App CI 與實機驗收進度統一記錄於 [主待辦](../../TODO.md)。

## 網路介面流量

設備頁沿用每秒前景取樣，讀取活動 `en*`／`pdp_ip*` 的 AF_LINK 位元組計數，分別顯示上行、下行的 Mbps 與容量／秒。

- 包含同一介面上其他 App 的流量，不能當作本 App 或推流獨占量。
- 不是網速測試；活動介面也不一定是 RTMP 使用的路由。
- 不加總 VPN／虛擬通道，避免與實體介面重複計算。
- 回前景重設基準；首次、介面消失重現、計數重設／回繞顯示等待取樣。
- 讀取失敗顯示錯誤，不把未知值顯示為零。頁面不可見時停止取樣。

## MetricKit 容量顯示

報告列表摘要與詳細頁預設自動換算容量；詳細頁可以切回原始單位。十進位 KB／MB／GB／TB 以 1,000 為進位，原報告的 KiB／MiB／GiB／TiB 先按 1,024 換算。時間、次數、未知單位維持原文，分享 JSON 不變。

## 驗收

- 兩種來源分別推流，確認同一組卡片收到新 session 的速率。
- ScreenCaptureKit 本地可控錄製、推流失敗後繼續錄製仍更新 Mixer；停止後不追加資料。
- 切出設備頁、回前景、切換 Wi-Fi／行動網路，首次無速率，下一筆才顯示差分。
- MetricKit 的 `117404 kB` 顯示 `117.40 MB`，切回原始單位仍為 `117404 kB`。
- Windows 可驗證純資料邏輯與 Swift 語法；Apple framework 型別檢查與實機取樣需由 Xcode CI／裝置驗收。
