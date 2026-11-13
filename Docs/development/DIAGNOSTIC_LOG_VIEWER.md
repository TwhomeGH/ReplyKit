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
- 搜尋：訊息、分類、session 與 `key=value` 欄位一起搜尋。
- 欄位展開：每行可展開 `key=value`，不用在一大串文字裡找數字。
- 分頁：預設 300 筆，按「載入更多」繼續。

## 判讀邊界

- 這是「分類與搜尋」工具，不會自動判斷因果或修正時間軸。
- `dropped`、`overflow`、`rebase` 是累積計數；看到非零不代表整個後續區段都在出錯，要搭配同一行的時間與其他欄位。
- 真正的錯誤以 `error`／`failed`／`Reconnect` 等事件為準；工具只做初步分級，最後仍需回到原始事件與量測。

## 測試

```bash
python -m unittest Scripts.test_diagnostic_viewer -v
```
