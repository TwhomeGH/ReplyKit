# CI 新執行取代舊執行

## 行為

- 單元測試、開發索引、tag 工作及 DocC：同一 workflow／ref 的新執行取消舊執行與舊等待項目；分支與 PR 的 ref 各自獨立。
- Archive／Release：依上游 workflow_run.head_branch 分組，從測試到建置均可被同分支的新發布執行取代。不是每次 push 立即取消，要等新的上游 tag 工作成功完成並觸發發布。
- 上游失敗或取消的 workflow_run 使用自身 run_id，不會取消正常發布。
- 被呼叫的單元測試使用 unit-tests 前綴，避免與發布父工作共用 concurrency 群組而互相取消。直接 push 的測試與發布前測試仍分開執行。
- DocC 建置按 ref 分組，Pages 部署另用共用群組序列化。

## 限制與驗收

- 這是新執行取代舊執行，不是固定等待幾分鐘的防抖。取消不會回滾已建立的 tag、Release 或已上傳的檔案。
- 舊 commit 手動重跑也屬新執行，concurrency 不會比較 commit 的新舊；需要測舊版時請注意同群組的執行。
- 修改合併後連續推送兩筆，確認舊測試與舊建置顯示 cancelled，最新執行持續；另一分支不受影響。
- 確認取消 tag 工作所產生的 completed 事件不會中斷最新發布；發布呼叫共用測試時父工作不會被子工作取消。
- 本機 YAML 檢查不能替代 GitHub 排程器實跑驗收。

參考：[GitHub workflow concurrency](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#concurrency)。
