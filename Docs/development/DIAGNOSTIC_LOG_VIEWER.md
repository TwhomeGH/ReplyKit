# 診斷日誌檢視器

把 `diagnostic-*.txt` 依 `[Tag]`、session 與嚴重度拆開，提供可搜尋的本機網頁；日誌不會上傳，也不需要外部套件。

## 啟動

```bash
python Scripts/diagnostic_viewer.py "E:\Video5\crash-symbols\diagnostic-20261113-0224-20261113-1458.txt"
```

預設開 `http://127.0.0.1:8766/`，並自動開啟瀏覽器。

```bash
# 不自動開瀏覽器
python Scripts/diagnostic_viewer.py <log.txt> --no-browser

# 指定起始 port；若已被占用會自動往下找（最多 20 個）
python Scripts/diagnostic_viewer.py <log.txt> --port 8777
```

按 `Ctrl+C` 停止。

## 功能

- 左側分類：`AVLag`、`CaptureAudioPipeline`、`CaptureTransport`、`CaptureVideoProcessing`、`Memory`、`IdleResources`、`RecordingFrame` 等，顯示各類行數。
- Session 篩選：從 `session=<UUID>` 自動抽取。
- 嚴重度：`error`／`warn`／`info`。`failed=0`、`lastError=none` 與累積的 `dropped=1` 不會被誤標成錯誤。
- 搜尋：訊息、分類、session 與 `key=value` 欄位一起搜尋；命中字串以 `<mark>` 高亮，訊息沒有命中但欄位／session 命中時自動展開欄位。
- 鄰近檢視：可選前後 0／2／5／10 筆；符合篩選的列正常顯示，鄰近列以淡色背景區分。跨頁載入會依原始行號去重；若同一列後來成為符合項，會升級為正常符合列。
- 欄位展開：每行可展開 `key=value`，不用在一大串文字裡找數字；高亮只用 DOM text node，不把日誌內容塞進 `innerHTML`。
- 分頁：預設 300 筆，按「載入更多」繼續。
- 時間範圍：全部時間、最近 15 分鐘／1 小時／6 小時／24 小時，或自訂 `datetime-local` 起訖。
  - 靜態診斷檔的「最近 N」以**檔案最新時間**為錨點，不是以開啟瀏覽器的現在時間；這樣三天前的長測仍能正確看最後一小時。
  - 時間由日誌的本地時間字串解析（支援 `清晨`、`上午`、`中午`、`下午`、`傍晚`、`晚上`、`深夜` 等時段）；沒有時間戳的行在有時間條件時不會被選入。
- 排序：時間舊→新（預設）或新→舊；排序只改顯示順序，不改變篩選與分頁語意。
- 鄰近筆數：前後 2／5／10 筆；與新→舊排序一起使用時，鄰近行也依同一方向排列。

### 與即時診斷頁的差異

TTWChatMessageServer 的 `/diagnostics` 是記憶體中的即時資料，因此有「自動更新」「Log I/O 卡片」「Socket 外部事件」；ReplyKit 檢視器讀的是 `diagnostic-*.txt` 靜態檔，沒有這些即時資料來源，不假裝提供。若檔案在瀏覽期間仍持續寫入，目前需重新啟動檢視器；尚未做 `--watch`。

## 判讀邊界

- 這是「分類與搜尋」工具，不會自動判斷因果或修正時間軸。
- `dropped`、`overflow`、`rebase` 是累積計數；看到非零不代表整個後續區段都在出錯，要搭配同一行的時間與其他欄位。
- 真正的錯誤以 `error`／`failed`／`Reconnect` 等事件為準；工具只做初步分級，最後仍需回到原始事件與量測。

## 測試

```bash
python -m unittest Scripts.test_diagnostic_viewer -v
```
