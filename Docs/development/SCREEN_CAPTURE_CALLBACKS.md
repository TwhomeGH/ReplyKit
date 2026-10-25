# ScreenCaptureKit 回呼入口診斷

`[CaptureCallbacks] schema=1` 與 CaptureSource 使用同一 session。擷取期間約每五秒回報，收尾排空後另記 stage=finished。

- callbacks：全部回呼，包含被忽略的樣本；video／audio／mic／unknown 分開。
- outcomes：invalid、notReady、missingStatus、nonComplete、missingImage、unknownType 為略過原因；offered 是嘗試交付 mailbox，不代表 mailbox 接受或成功推流。
- states：可解析的畫面狀態 complete／idle／blank／suspended／started／stopped／unknown；不依此推定遊戲或系統故障。
- idleSeconds：距最後回呼時間；沒有回呼為 unknown。maxCallbackGapSeconds 為 session 累計最大間隔，不是這五秒區間的最大值。
- lastPTS、regress、invalidPTS：來源時間與異常計數，包含未交付 mailbox 的樣本。
- hostMinusPTSSeconds：回呼入口 host clock 減樣本 PTS；min／max 為累計極值。時基尚未驗證，不能直接稱為擷取延遲；負值保留，無效 PTS 顯示 unknown。

## 判讀

callbacks 不增加而 idleSeconds 增加，表示 App 沒觀察到新回呼；不能區分系統未交付與回呼佇列未獲排程。callbacks 增加但 offered 少，查 outcomes／states。offered 多但 mailbox 接受少，查 CaptureSource 丟棄計數。Mixer／編碼輸入少則繼續對照後續佇列與旋轉錯誤。

資料只描述回呼與來源時間，不能單獨證明畫面內容新鮮、GPU 正確或伺服器成功解碼。尚需實機對照 10/25 類似活動頁面、靜止畫面與前後景切換。

## 起始與 PCM 時間對照

CaptureCallbacks 的 firstArrival 是第一個回呼時間，firstPTS 是第一筆有限來源時間，兩者不一定出自同一筆有效影格。MixerOrigin 每個 probe 各記一次影音時間，session 是 probe 的 UUID；須依既有 StreamDiagnostics 快照關聯，不等於 CaptureCallbacks 的擷取 session。

CaptureAudioPipeline 的 audioTimeline 包含來源 track0／track1 與 mixed。frames 為 sample frames，不乘聲道數；contentSeconds 為每批 frames/rate 累計，spanSeconds 為最後一批結束 PTS 減第一批 PTS。spanMinusContentSeconds 為跨度減內容秒數，正值可能是間隔，負值可能是重疊；不能直接當作口型差或漏音量。discontinuities 計算超過 1.5 個 sample 的間隔或重疊。

格式改變即重開統計世代；混音需有效 hostTime，否則只計 invalid。來源格式無法讀取時目前未納入此統計，應對照 CaptureCallbacks。未加任何時間補償。

後續仍需編碼首包、RTMP 入列首包、重連／編碼重建世代與完整影格跨階段關聯。ReplayKit 目前只有共用 Mixer 首筆時間，分軌內容時長待接入。

## 畫面加工與編碼邊界

`CaptureVideoProcessing` 每五秒及停止排空後記錄：嘗試、加工成功、原樣通過、失敗數，最近／最高總耗時、同幀前後 PTS，以及來源／畫布尺寸、左轉、裁切、疊加狀態。`overlayPrepareMs`、`renderCallMs` 是各呼叫的經過時間，不等同純 GPU 執行時間；失敗時可能沒有後續階段欄位。統計固定大小，未保留媒體 buffer。

設定每秒最多讀取／解碼一次；串流設定變更最多約一秒後在下一幀套用。時間層生成失敗會累計 overlayDegraded，繼續輸出無時間層影片；旋轉／畫布或緩衝分配失敗才丟幀。這批只覆蓋 ScreenCaptureKit 本機加工；系統直接錄製與 ReplayKit 的加工器不提供此摘要。

設備資訊的串流明細同步顯示加工摘要、VT 首筆／最新同幀時間，以及兩軌 RTMP 首筆嘗試／首筆成功／最新入列時間。RTMP 欄位透過既有共用快照傳遞，ReplayKit 也使用同一入口。入列不是網路送達；VT session 與發布 generation 是不同識別，兩軌最新樣本不代表同步配對。

App 疊加時鐘是在加工當下產生，不能當作原始擷取時鐘。完整擷取到 RTMP 的逐幀識別關聯、ReplayKit 分軌音訊內容跨度仍待補強。Apple CI 與實機需確認旋轉、疊加開關、來源尺寸變更及長時間推流的觀測結果。

### 加工效能與色彩契約

- 時間層以 Core Image 與來源合成後一次 render，取消 GPU 渲染後 CPU 鎖定整張影格繪圖的路徑。
- 優先採來源 CIImage 的 RGB 色彩空間；缺漏時明確採 sRGB 後備，摘要記錄 colorPolicy。輸出 buffer 清除舊附件後設定實際 RGB 色彩空間，不複製 YUV matrix/range 或 HDR metadata。輸出仍是 8-bit BGRA，不保證完整 HDR 保真。
- 池上限由 48 MiB 像素估算預算與對齊後列大小推算，最多六張；單張超預算拒絕。這不是程序總記憶體保證，亦不涵蓋尺寸切換仍在途的舊池影格。
- 每幀只保存純量，摘要才格式化字串；提供累計平均、最大耗時、超過 16.67ms 次數、疊加降級與池耗盡數。16.67ms 是 60fps 觀測參考，不是丟幀門檻。
- 字體與貼圖尺寸加上上限，位置及畫布拒絕非有限值。實機仍需確認文字方向、透明度、色彩與不同解析度的耗時。

### 加工 worker 忙碌比例

`CaptureVideoProcessingLoad` 每輪診斷取樣一次，設備資訊 → 串流格式與 RTMP 傳輸 → ScreenCaptureKit 顯示同一筆區間結果。以加工忙碌秒數除以實際區間秒數，週期目標五秒；首次只建立基準，沒有資料不冒充零。計入跨區間尚未完成的加工，不含等候來源影格、Mixer 或編碼器的時間。包含加工內部同步等待，不能稱作 CPU／GPU 使用率。停止後保留最後取樣歷史，不繼續累計。

### ReplayKit 旋轉加工接入

ReplayKit 的 GPU 旋轉器經既有 Socket 快照每五秒回報，設備資訊 → 串流格式與 RTMP 傳輸 → ReplayKit 顯示「Metal 加工在途比例」及加工摘要。時間層未編入時 overlayEncoded=false，旋轉／尺寸加工仍統計。

在途比例為至少一筆命令尚未完成的區間聯集，並行命令不重複計時；watchdog 逾時不提前當作完成，實際回呼才扣除在途數。preparationMs 包含準備及可能等待，submitToCompletionMs 包含排隊與執行，兩者都不是 CPU／GPU 使用率。rotationDegrees、resized、canvas 描述最近提交命令；不是獨立旋轉或縮放 GPU 耗時。

追蹤器隨旋轉器重建換 ID，首次僅建立基準。CPU 後備顯示 load=unavailable；摘要提供 consecutiveDrops，避免把凍結畫面後備誤當成正常新畫面。尚未涵蓋舊旋轉器重建後仍未完成命令的跨實例負載合計。
