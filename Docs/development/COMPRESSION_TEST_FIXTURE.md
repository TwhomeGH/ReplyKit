# 壓縮測試影片

`liveAPPTests/compression-source.mp4` 是 FFmpeg 產生的合成圖樣，不包含實際錄影或個人資料。規格為 H.264 Baseline、320×240、30 FPS、1 秒、無音訊、YUV 4:2:0 有限範圍與 BT.709 色彩標記。

測試 target 使用檔案系統同步群組，MP4 由 Xcode 當作資源加入測試 bundle。測試以 bundle 內的固定影片複製到獨立暫存目錄，然後真正執行手動碼率與系統品質壓縮；不再於準備階段另啟動編碼器。樣本缺少時直接失敗，不略過測試。

重建指令（於專案根目錄執行；不同 FFmpeg 版本不保證逐位元組一致）：

```sh
ffmpeg -f lavfi -i "testsrc2=size=320x240:rate=30:duration=1" -an -c:v libx264 -profile:v baseline -pix_fmt yuv420p -crf 28 -g 30 -color_range tv -colorspace bt709 -color_primaries bt709 -color_trc bt709 -movflags +faststart liveAPPTests/compression-source.mp4
```

這個案例驗證原檔不變、輸出影片時長及影格可解碼；不涵蓋音訊保留或所有來源色彩組合。真正壓縮仍依賴 Apple 平台編碼能力，相關失敗應繼續由 CI 回報。
