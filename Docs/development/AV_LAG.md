# A/V 內容延遲診斷（AVLag）

## 快速入口

- 裝置資訊頁 → **A/V Lag** → **查看目前 AV Lag 報告**
- 報告頁可複製／分享 JSON，給回放 retime 工具做交叉比對；分享的是實際 `.json` 檔案，可直接交給分析工具
- 日誌關鍵字：`[AVLag]`

## 這份報告回答什麼

`videoContentAge`（介面顯示「影片內容延遲」）是「擷取回呼到達時間 - 影片來源 PTS」：

```text
videoContentAge = arrival - videoPTS
```

正數表示影片內容比回呼時間舊，也就是畫面內容落後。這與音訊是否正確是兩個獨立問題；audio 正常但 video content 落後時，不能只看 A/V timestamp 是否回退。

其他欄位：

| 欄位 | 意義 |
| --- | --- |
| `videoQueueAge` | 回呼到 worker 取得樣本的時間 |
| `videoQueueOldestAge` | 擷取佇列目前最舊樣本已等待秒數；欄位名稱保留相容，實際語意是 queue delay。佇列為空時顯示 empty，不是尚未實作 |
| `videoIdleAge` | 距離最後一次影片回呼的時間；用來判斷目前數字是否已過期 |
| `videoProcessAge` | 回呼到影片加工完成的時間 |
| `videoSourceAge` | 加工完成時間 - 影片來源 PTS |
| `audioContentAge` | 系統音訊回呼到達時間 - 音訊來源 PTS |
| `sourcePTSDelta` | `videoPTS - audioPTS`，只作交叉比對 |
| `sourcePTSDeltaDrift` | 相對本 session 第一筆有效 `sourcePTSDelta` 的累積變化；負值代表音訊 PTS 持續往後 |
| `sourcePTSDeltaPerMinute` | 上述漂移換算成每分鐘變化 |
| `avClockDrift` | `audioContentAge - videoContentAge`，觀察來源時鐘相對 host clock 的漂移 |
| `avSyncState` | `stable`／`drifting`／`jumped`；只作診斷，不直接修改時間戳 |
| `contentAgeJump` | 與上一次內容延遲相差 ≥1 秒時記錄；沒有階梯事件時顯示 none，不是尚未實作 |
| `videoQueue` | `CaptureMailbox` 的 queued／dropped／bytes 摘要 |

`unknown` 代表尚未取得該階段資料，不把 0 當成有效值。`videoQueueOldestAge` 的 empty 是「目前沒有待處理樣本」，`contentAgeJump` 的 none 是「這段時間沒有 ≥1 秒階梯」，兩者都不是功能未完成。`videoContentAge` 假設來源 PTS 與 host clock 可比較；目前 `[CaptureCallbacks]` 仍標示 `clockComparison=unverified`，所以要和 PiP 計時器／遊戲內事件交叉確認，不能只憑這個欄位斷言畫面延遲。

## 日誌與保留

- 一般 `[AVLag]` 每 10 秒一筆；啟動 60 秒內維持較密集。
- 內容延遲 ≥1 秒或出現 `contentAgeJump` 時即時記錄。
- 報告序列每 5 秒取樣，單一 segment 的樣本數依「每段長度」設定，並受 2 MiB 上限限制；新的擷取 session 會重新開始。
- `[AVLag]` 不會自動修改播放檔案；只提供診斷與 retime 參考。

## 保存與長場次分段

- 預設**僅本次記憶體**；關閉 App 即清除。
- 可選**保留最近 5 場**：停止時寫入 `Documents/AVLagReports`，最多 5 個 session、總量約 50 MiB。App 的 `Info.plist` 已啟用 `UIFileSharingEnabled`，因此可在「檔案」App → 我的 iPhone → 松鼠推流 → `AVLagReports` 直接看到。
- 可選**長場次分段**：每段長度 1／2／4／8 小時（預設 4）；每段仍受 2 MiB 上限。8 小時以上會自然拆成多段，但報告頁以 `sessionID` 分組，不會當成多場。
- 分段之間保留 `segmentIndex`／`segmentStartedAt`／`segmentEndedAt`；最後一段可標記 `inProgress`，App 中途被殺仍可辨識。
- `complete=false` 的檔案是進行中 checkpoint，不是最終報告。若只有 3 筆樣本且時間只涵蓋開始後十幾秒，先看它的 `startedAt`／`segmentStartedAt`，不要直接當成長場次結論；目前報告頁的「目前 session」應在停止後再分享。
- 未開分段而超過上限：保留最新區間，並在報告標記 `truncatedBefore`。
- `recentSessions` 模式每 60 秒會 checkpoint 進行中的 segment；停止、分段與進背景時也會保存。長場次被中止時，檔案最多落後一個 checkpoint 週期，不會只剩進入背景當下的少量樣本。
- 儲存任務依呼叫順序串接；較舊的 checkpoint 不會覆蓋較新的 final 文件。寫檔為原子寫入，不阻塞擷取。
- 目前報告與每個已保存 segment 都可分享成 `.json` 檔案；文字複製仍保留給快速檢查。報告檔同時寫在 `Documents/AVLagReports`，可直接從「檔案」App 取得。

## JSON 用途

`schema=1` 的 JSON 包含 session、開始／結束時間，以及每筆樣本。回放修復工具可用：

1. 以 `audioPTS` 作媒體時間軸。
2. 以 `videoContentAge` 找內容落後的區段。
3. 以 `sourcePTSDelta` 或 `videoSourceAge` 交叉確認是否為來源／管線延遲。

不要直接把單一 `videoContentAge` 當成固定位移套用到整段影片；先確認曲線是階梯、漂移，還是只有部分區段。

## 判讀順序

1. `videoContentAge` 與 `videoQueueOldestAge` 同時階梯上升 → 影片管線 backlog，優先查 queue／PiP／主執行緒 stall。
2. `videoContentAge` 穩定但 `publishPTS - sourcePTS` 變大 → timestamp 重基準。
3. `sourcePTSDeltaDrift`／`sourcePTSDeltaPerMinute` 長期單向變化 → 來源音訊時鐘或 audio preferredDelta；先看 `avClockDrift` 是否同時變大。
4. `avSyncState=jumped` 表示 10 秒內來源 A/V 差突然超過 100 ms；只當事件，不要直接推論整段漂移。
5. 只有 PiP 計時器落後、遊戲畫面正常 → 檢查 overlay timer 本身，不要用 timer retime 整段 video。
