# GPU 輸出 Pool 與使用期限

## 2026-09-10 修正

原本 GPU completion 將 `ReusableOutputSet` 放回陣列，再回傳包裝同一個 pixel buffer 的 sample buffer。下游尚未讀完時，下一幀可能取出並覆寫相同儲存空間。陣列的鎖不能保護下游讀取期限。

現在每個輸出尺寸使用 `CVPixelBufferPool`，透過 `CVPixelBufferPoolCreatePixelBufferWithAuxAttributes` 配置 buffer，不再手動回收 output set。GPU completion 持有本幀 textures；回傳的 sample buffer 與最後好幀引用保留 pixel buffer，直到消費者釋放後才允許重用。

`maxPoolSize` 現在限制每個 pool 的配置數量，至少為 3，包含使用中的 buffer；達到門檻時丟棄本次輸出，交由既有 fallback 處理，不當成 Metal 裝置故障。這與舊版只限制閒置陣列長度不同。

GPU 成功幀直接保存 pixel buffer 引用作為 freeze snapshot，省去每幀 `CVPixelBufferCreate` 和整張 CPU memcpy。CPU fallback 仍保留原本的 snapshot 複製。每幀仍會建立 texture wrappers 與 format description，尚未量測此成本，不能宣稱端到端效能已提升多少。

`outputPoolLock` 保護 pool 字典及 active 狀態，配置 buffer 與建立 textures 在鎖外執行。cleanup 在鎖內移出 pool 字典並取得數量，解鎖後釋放空閒 buffer；不再解鎖後讀共享字典。已提交的 GPU 工作與下游引用繼續持有自己的資源。

## 驗證

本機為 Windows，無 Swift/Xcode 工具鏈，僅完成差異與靜態檢查。合併前需在 macOS 編譯及真機確認：

- 30/60fps 持續推流，包含輸出 overlay、旋轉與尺寸切換。
- 下游延遲持有多幀時，舊幀內容不被新幀覆寫。
- pool 達門檻、GPU timeout、重建與停止直播期間不崩潰。
- 比較 CPU 使用率、記憶體、丟幀與 GPU completion latency；最後好幀會固定持有一個 buffer。
