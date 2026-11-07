# A/V 內容延遲診斷（AVLag）

## 快速入口

- 裝置資訊頁 → **A/V Lag** → **查看目前 AV Lag 報告**
- 報告頁可複製／分享 JSON，給回放 retime 工具做交叉比對
- 日誌關鍵字：`[AVLag]`

## 這份報告回答什麼

`videoContentAge` 是「擷取回呼到達時間 - 影片來源 PTS」：

```text
videoContentAge = arrival - videoPTS
```

正數表示影片內容比回呼時間舊，也就是畫面內容落後。這與音訊是否正確是兩個獨立問題；audio 正常但 video content 落後時，不能只看 A/V timestamp 是否回退。

其他欄位：

| 欄位 | 意義 |
| --- | --- |
| `videoQueueAge` | 回呼到 worker 取得樣本的時間 |
| `videoQueueOldestAge` | 擷取佇列目前最舊樣本年齡；佇列為空時顯示 empty，不是尚未實作 |
| `videoIdleAge` | 距離最後一次影片回呼的時間；用來判斷目前數字是否已過期 |
| `videoProcessAge` | 回呼到影片加工完成的時間 |
| `videoSourceAge` | 加工完成時間 - 影片來源 PTS |
| `audioContentAge` | 系統音訊回呼到達時間 - 音訊來源 PTS |
| `sourcePTSDelta` | `videoPTS - audioPTS`，只作交叉比對 |
| `contentAgeJump` | 與上一次內容年齡相差 ≥1 秒時記錄；沒有階梯事件時顯示 none，不是尚未實作 |
| `videoQueue` | `CaptureMailbox` 的 queued／dropped／bytes 摘要 |

`unknown` 代表尚未取得該階段資料，不把 0 當成有效值。`videoQueueOldestAge` 的 empty 是「目前沒有待處理樣本」，`contentAgeJump` 的 none 是「這段時間沒有 ≥1 秒階梯」，兩者都不是功能未完成。`videoContentAge` 假設來源 PTS 與 host clock 可比較；目前 `[CaptureCallbacks]` 仍標示 `clockComparison=unverified`，所以要和 PiP 計時器／遊戲內事件交叉確認，不能只憑這個欄位斷言畫面延遲。

## 日誌與保留

- 一般 `[AVLag]` 每 10 秒一筆；啟動 60 秒內維持較密集。
- 內容年齡 ≥1 秒或出現 `contentAgeJump` 時即時記錄。
- 報告序列每 5 秒取樣，單一擷取 session 最多保留 10,000 筆；新的擷取 session 會重新開始。
- `[AVLag]` 不會自動修改播放檔案；只提供診斷與 retime 參考。

## JSON 用途

`schema=1` 的 JSON 包含 session、開始／結束時間，以及每筆樣本。回放修復工具可用：

1. 以 `audioPTS` 作媒體時間軸。
2. 以 `videoContentAge` 找內容落後的區段。
3. 以 `sourcePTSDelta` 或 `videoSourceAge` 交叉確認是否為來源／管線延遲。

不要直接把單一 `videoContentAge` 當成固定位移套用到整段影片；先確認曲線是階梯、漂移，還是只有部分區段。

## 判讀順序

1. `videoContentAge` 與 `videoQueueOldestAge` 同時階梯上升 → 影片管線 backlog，優先查 queue／PiP／主執行緒 stall。
2. `videoContentAge` 穩定但 `publishPTS - sourcePTS` 變大 → timestamp 重基準。
3. `videoSourcePTS - audioSourcePTS` 長期漂移 → 來源時鐘或 audio preferredDelta。
4. 只有 PiP 計時器落後、遊戲畫面正常 → 檢查 overlay timer 本身，不要用 timer retime 整段 video。
