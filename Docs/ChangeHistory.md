# 變更歷史

## 2026.11.10 音訊主時鐘與 RTMP 診斷可讀性

- `CaptureMediaPipeline.audioSettings` 在麥克風啟用時改用 mic（track 1）作為 Mixer 主時鐘，輸出格式仍取 App 軌；避免 App 軌靜默但持續 callback 時，mic 被當成非主軌反覆 align／丟樣本而斷續。mic 停止或關閉時，底層 `activeClockTrack` 會 fallback 到 App 軌。
- 2ch mixer 測試現在會斷言輸出內容不是靜音（`channelRMS`），補上先前只檢查格式、未檢查實際混音的盲點。
- `AudioPipelineDiagnostics.Track` 新增每軌輸出 RMS；`ScreenCaptureSource` 的 `[CaptureAudioPipeline]` 同時記錄 `alignDrop`／`alignInsert`／`alignDiff`，可區分麥克風真正斷斷續續與只看到 mixed snapshot。
- 「Audio Pipeline · 混音輸出」新增「音訊轉換器」區塊：顯示 App／Mic 的 AVCon status、convert／noData／inputRanDry／error、input／output samples、ring buffer、align 與 RMS；不把 AVCon 歸到 VT 或 RTMP。
- 修正 CI 測試摘要把斷言失敗誤標成 `[Runner infrastructure]`；`test-without-building` 的測試失敗保留為測試結果，只有逾時／啟動失敗才標成 runner 環境。
- 「串流格式與 RTMP 傳輸」改為摘要＋可收合子區塊（格式與編碼／VT 編碼器／RTMP 傳輸／入列時間軸），不再把數十個明細塞在同一張 DisclosureGroup。
- AV Lag 已保存場次在讀取索引時會清理不存在的 segment 檔；非目前 active 且 `endedAt` 仍為 nil 的舊場次會標成「未完成（已中斷）」，不再永久顯示「進行中」。
- `inspect_app_bundle.py` 只在實際 IPA 輸入時顯示 `IPA ZIP 大小`；`.app` 目錄改標示「封存 .app，沒有 IPA ZIP」，分類與最大檔案不再列出容易誤導的逐檔 `ZIP 壓縮大小`。測試補上 IPA 與 `.app` 兩種報告格式。
- `add_legacy_alternate_icons.sh` 不再把未被 `CFBundleIconFiles` 引用的 1024 `PersonalIcon.png` 複製到 App 根目錄；Assets.car 仍保留 marketing rendition，約減少 1.79 MB 的重複圖示資料。
- `AppIcon.appiconset` 原本的 `AppIcon 1.png`／`AppIcon 2.png` 不是不同尺寸，而是與 default 相同 SHA256 的 dark／tinted appearance 變體。已移除兩張重複檔，只保留單張 1024 default；iOS 其餘尺寸由 actool 產生，不再以 legacy 多尺寸重複塞入 catalog。
- GPU 旋轉處理設定頁改為 `AdaptiveSettingsGrid` 卡片：配置、畫布尺寸、方向與縮放三個區塊；寬螢幕並排、窄螢幕單欄，OD／AD 寬高欄位以同一列呈現，減少 iPad 全域捲動。
- 新增 base64 `data:image/...` 圖片來源：聊天頭像／禮物、行內 emoji、贊助橫幅與通知共用本機解碼，不進 URLSession；限制單張 256 KiB、單訊息 768 KiB、4 MP，拒絕 SVG／非 base64／超量，HTTP URL 仍保留給大圖。日誌以長度遮蔽 base64，TTS 與通知使用清洗後文字。
- ReplayKit 的 `StreamDiagnosticsSnapshot` 現在也會帶 `audioTracks`；主 App 的「Audio Pipeline · 混音輸出」在 ReplayKit 與 ScreenCaptureKit 都能看到 App／Mic 的 AVCon、ring buffer、align 與 RMS。轉換邏輯集中在 `StreamDiagnosticsSnapshot.audioTrackDiagnostics(from:)`，避免兩條路徑各寫一份。
- `[IdleResources]` 新增 `warmIdleBaselineMB`／`deltaWarmIdleMB`：每次進入擷取前記錄最近一次已穩定的 idle footprint，包含 DeviceInfo／Settings／Audio／PiP 等 UI 常駐成本；`coldIdleBaselineMB` 保留作冷啟動對照，避免把 100 MB warm idle 誤算成串流增量。
- 修正 DeviceView 與 FileLogView 的週期 task：不再使用 `.task(id:)` 由布林狀態重啟，改成頁面可見且前景時才啟動單一 `Task`，離頁／背景立即取消；避免隱藏分頁或重複 view 持續每秒取樣、刷新日誌而累積記憶體。診斷 log 的 sampling start／stop 會用來確認沒有重複 task。
- 外部日誌設定文案改為說明「回送防護」：擴展送出的日誌不會再被回送給擴展；只有已訂閱的外部工具會收到 `externalLogBatch`／`diagnostic`，避免被誤解成擴展完全不傳任何資料。
- 修正 `DebugPipeline` toggle 沒有 observer 的問題，加入 `Eventlisten`；`DebugRotate`／`DebugTime`／`DebugPipeline`／`RotateOriginal`／`Rotate`／`SocketLog` 改成優先讀 App Group，只有沒有 App Group（側載）才用 Socket 單 key 查詢，移除每個 toggle 一次 `requestSet` 的重複與競態。`DebugTime` 仍只控制 ReplayKit 的 rotator timestamp；SCK 沿用 AVLag，暫不新增第二套。
- 新增 `RuntimeDebugConfig` versioned snapshot：正常安裝由單一 `liveAPP.runtimeDebugConfig` 通知套用 rotate／time／pipeline／socket debug flags，並一併帶入 `Rotate`／`RotateOriginal` 幾何設定；擴展只在幾何值變更時重建 encoder，避免每個 debug toggle 都重啟影片編碼。舊 snapshot 以 `includesGeometry=false` 相容，不會用預設 90° 覆蓋目前方向；側載仍保留舊事件與 Socket fallback。
- `Package.resolved` 更新到 fork `9beb2a93`；ReplyKit CI／實機仍待驗。

## 2026.11.09 音訊 2ch Mixer 與套件接入

- 修正 `AudioMixerByMultiTrack` 2 聲道 setup：macOS Float32 使用 non-interleaved，iOS Int16 使用 interleaved；1 聲道維持 interleaved。先前 `MultiChannelMixer` 的 input stream format 會回 `-10868`，導致 mixer 未 ready、App 軌沒有輸出。
- 補上 `setup[stage]` 診斷與 2ch 輸出斷言；原本 `test48000_2ch` 只檢查格式、沒有 assert 輸出，才讓缺陷被隱藏。
- 修正 CI 摘要分類：`test-without-building` 的斷言失敗不再寫成 `[Runner infrastructure]`，只有 runner 連線失敗、逾時或無測試結果才標成環境失敗；`build-for-testing` 非逾時失敗歸類為編譯錯誤。
- `Package.resolved` 與 Xcode workspace 的 `Package.resolved` 都更新到 fork `d434db40`；fork CI 已驗證 2ch 修正，ReplyKit CI 待跑。
- fork 提交：`cecd7e26`、`bc78fe84`、`d434db40`。

## 2026.11.09 23:10 動態範圍與 FPS 語意

- 動態範圍註釋改為中文，明示 SDR／HDR 的 pixel format、color space、Screen renderer 與相機路徑差異；HDR 仍不支援即時串流。
- `VideoCaptureUnit.setDynamicRangeMode` 改為 `throws`，`MediaMixer.setDynamicRangeMode` 不再以 `try?` 吞掉相機不支援錯誤；attach 時也 propagated。
- `MediaMixer.setFrameRate` 明確只控制相機 frame rate（所有 camera device），新增 `setDisplayFrameRate` 控制 offscreen display link；`frameRate` 與 display FPS 脫鉤，避免把相機 FPS 當成 encoder 輸出上限。
- fork 本地提交 `e9d26ec6`、`6b75f9a7`、`a6c9be39`，尚未 push。

## 2026.11.09 23:00 VT 編碼器健康摘要

- HaishinKit 新增 `VideoEncoderHealth`，由 `VideoPipelineEventsSnapshot` 推導 VT submitted／delivered／dropped／filtered／keyframe suppressed／yield rejected／failure／PTS reset，並帶 `pendingFrames`。
- `VideoCodec` 每 0.5 秒取樣 `NumberOfPendingFrames`；`VideoPipelineSnapshot` schema 3 新增 `encoderHealth`（舊快照可缺欄位）。
- `StreamDiagnosticsSnapshot` 轉送 `encoderHealth`，主 App 的串流診斷頁先顯示狀態摘要；完整設備資訊 UI 仍待後續。
- 狀態分開標示 `vtDrop`、`outputRejected`、`waitingKeyFrame`、`throughputThrottle`、`ptsReset`，避免把 App 節流誤判為 VT 丟幀。
- fork 本地提交 `f4254620`，尚未 push；CI／實機未驗。

## 2026.11.09 22:40 AVAudioConverter 診斷

- `AudioPipelineDiagnostics.Track` 新增 `converter`：記錄 AVCon 的 convert 次數、輸出狀態、input callback 請求／供應 frames、輸出 frames、zero output、converter 重建、格式與最近錯誤。
- `AudioMixerTrack` 在每次 resample 時累計；可區分正常 `.noDataNow`、`.inputRanDry`、`.error` 與 underrun。
- AAC `AudioCodec` 的 encoder converter 尚未接入同一摘要；目前先覆蓋 app／mic 的重取樣層。
- fork 本地提交 `a281d197`，尚未 push；CI／實機未驗。

## 2026.11.09 22:20 Keyframe 與 BufferCount 明確策略

- `maxKeyFrameIntervalDuration == 0` 改為真正的 automatic：`makeKeyFrameIntervalOptions` 不再送 duration／frame interval option，也不 fallback 成 2 秒；預設仍是 2 秒。
- App 新增 `KeyFrameIntervalPolicy` 與 `VideoBufferPolicy`：`<= 0` 統一視為 automatic，固定值分別 clamp 到 60 秒與 100 幀；ReplayKit／SCK 共用，修正兩端 clamp 與預設值不一致。
- `BufferCount == 0` 不再走 undefined 的 `maxFrameDelayCount=0`，統一映射成 VT 的 `-1` 與 `setVideoInputBufferCounts(nil)`；`Event` 預設由 5 改回 -1。
- UI keyframe／BufferCount 輸入加入範圍正規化；回歸測試覆蓋 policy 與 keyframe automatic。

## 2026.11.09 22:00 Release 名稱自動分類

- 新增 `Scripts/release_classification.json`、`Scripts/classify_release.py` 與測試；依變更路徑自動產生 Core／UI、Audio／Video／RTMP／PiP／Extension／Settings 標籤。
- `Exp` 以 tag 歷史計算：Core 變更後 5 個 release 內標示，不再需要手動修改 Release 名稱。
- `Hotfix`／`Major` 只能由 commit trailer `Release-Label:` 指定；UI-only fix 可由 conventional commit 自動標 `UIFix`。
- `main.yml` 在建立／更新 Release 時寫入分類名稱與 body；同時修正 `MERGED_BODY` 變數拼字，既有 Release 也會更新 name。
- tag 維持純 `x.y.z`，分類不寫入 git tag。

## 2026.11.09 21:35 音訊環形緩衝格式與 PTS 缺陷

- 修正 `AudioRingBuffer` 以 Int16 指標處理 Float32／Int32 的問題；copy、render、zero 改走 `AudioBufferList.mData` 原始指標並依 `bytesPerSample` 位移，避免第二個 render 後 channel 錯位、爆音或靜音。
- 新增 Float32 非交錯跨 render 測試，以及來源 PTS 大幅倒退時重建緩衝的測試。
- `AudioMixerTrack` 的 `AudioTime` 只在不連續 >1 秒時重建 anchor；正常連續幀不反覆覆寫來源時間。
- fork 本地提交 `56d1e93c`；尚未 push。

## 2026.11.09 21:20 混音時鐘擁有者切換

- 修正 HaishinKit fork `14c41945`：`activeClockTrack` 只在 main 停止、接手軌停止或 main 恢復時切換；正常連續音訊不再每幀覆寫 `sampleTime`。
- 只有時鐘擁有者改變或時鐘軌 PTS 跳躍 >1 秒才重設 `sampleTime`/`anchor`；`render()` 不再對 active clock track 做 `align`，避免兩軌混音被切碎。
- 來源端後續更新 PTS 由 `AudioRingBuffer` 記錄；不會反覆覆寫 mixer 播放頭。fork 尚未 push。

## 2026.11.08 21:10 文件標題階層與本機檢查

- 修正 `Docs/av-pipeline.md` 在 h2 後直接跳 h4 的 MD001；AHealth 子標題改為 h3。
- `Scripts/check_markdown.py` 新增 MD001 檢查，CI 的 Development index 改用同一個入口，本地 hook 也會先擋下標題階層錯誤。

## 2026.11.08 20:55 混音主軌停止的底層 fallback

- HaishinKit fork 本地提交 `15d59bef`：`AudioMixerByMultiTrack` 追蹤各軌最近輸出時間，main track 超過 250ms 無輸出即由其他軌接手，並重設 `sampleTime`/`anchor`，避免 App 軌被舊 main 位置 align 丟棄。
- `MixClockAdvance.shouldAdvance` 新增 `mainIsActive`；補 main 停止/移除測試。
- ReplyKit 仍以 App 軌為 `mainTrack`/`outputFormatTrack`；底層 fallback 是第二道防線。fork `15d59bef` 已 push；`Package.resolved` 已更新並提交 `d7814fc`。

## 2026.11.08 20:40 App 主音軌與音量滑桿範圍

- App 軌改為 mixer `mainTrack` 與 `outputFormatTrack` 的唯一基準；mic 只作為第二軌。先前主軌指向 mic，mic 關閉或停止送資料後 App 會被當成非主軌對齊，造成完全沒有 App 聲音；`ReplayVolumeSynchronizer` 也不再要求 mic 軌存在才套用 App 音量。
- 音量滑桿最低非零值由 `-140 dB` 改為 `-40 dB`：0% 靜音、50% 約 `-20 dB`、100% `0 dB`；-38.9 dB 現在落在左端約 2.7%，不再顯示在中段。UI 端點標示改為靜音／-20 dB／0 dB。
- 新增 `AudioMixerRoutingTests` 與 `AudioVolumeSliderTests`。

## 2026.11.08 20:20 編碼縮放模式入口

- ReplayKit 的 HaishinKit `ScalingMode` 不再寫死 letterbox；進階編碼新增 Letterbox／Trim／Normal 選項，預設仍為 Letterbox。
- ScreenCaptureKit 的縮放由 `StreamFramePolicy` 與 `ScreenStreamVideoRotator` 處理，encoder 固定 Normal，避免 compositor 與 VideoToolbox 二次 letterbox。
- `videoScalingMode` 納入非敏感設定備份；E-RTMP 與低延遲確認在 SCK 的 RTMPConnection／video settings 生效。

## 2026.11.08 20:00 進階編碼 CAVLC／VT 速度拆分

- 將 `h264useCAVLC` 拆成兩個獨立設定：CAVLC 只控制 H.264 entropy；`vtSpeedPriority` 單獨控制 `prioritizeEncodingSpeedOverQuality` 與實驗性軟體節流。
- 舊版 `h264useCAVLC=true` 會在新鍵不存在時遷移為 `vtSpeedPriority=true`，避免升級後突然失去原本的 VT 速度策略。
- ReplayKit 與 ScreenCaptureKit 都接上兩個設定；SCK 另外套用至 `RTMPStream` 的 video settings。
- 進階編碼頁改為位元率、H.264 相容性、VideoToolbox、RTMP 四段；SCK 的 RTMP 連線也接上 E-RTMP 與低延遲設定，B-Frame 仍固定關閉並標示。
- Socket 配置加入 `vtSpeedPriority`，非敏感設定備份同步納入。

## 2026.11.08 19:30 共用串流幾何與 RTMP／GPU 設定歸屬

- 新增 `SharedCapture/StreamGeometry.swift`：ReplayKit 與 ScreenCaptureKit 共用 OD／AD／旋轉／capture buffer 的尺寸決策，旋轉只轉置 capture，不重複改寫 encoder canvas。
- ReplayKit `SampleHandler` 與 SCK `ScreenCaptureSource` 改接共用幾何；SCK 套用 `BufferCount` 到 RTMP stream／VideoToolbox。
- `BufferCount` 從 GPU 頁移到編碼設定，明確標示為 RTMP／encoder 緩衝；`useBic` 留在 GPU 頁但只在 ReplayKit 顯示，SCK 顯示說明。
- 新增 `CaptureStreamGeometryTests` 覆蓋固定畫布、OD／AD fallback、旋轉與無效尺寸。

## 2026.11.08 19:00 本機 Markdown 空行檢查

- 新增 `Scripts/check_markdown.py`，與 development-index workflow 共用 MD012 檢查；不再依賴 `npx markdownlint-cli`，避免只有 CI 才發現連續空白行。
- 新增可選 `.githooks/pre-commit`；執行 `git config core.hooksPath .githooks` 後，commit 前會自動檢查。
- 修正 `Docs/development/AV_LAG.md` 尾端多餘空白行。

## 2026.11.08 18:05 分類文件靜態站接入 DocC Pages

- ChangeLogKit 預設使用 `main` 安裝，不使用本機 ChangeLogTools 絕對路徑；可用 repository variable `CHANGELOGKIT_REF` 指定 branch/tag，CI 會把實際 commit 寫入摘要。安裝後匯出到 `site/project/`。
- DocC 根首頁新增 `./project/` 入口；文件 workflow 的 path／diff 預檢加入 `Docs/`、`README.md`、`TODO.md`、`.changelog.toml` 與 `Scripts/validate_pages.py`。
- 新增 `Scripts/validate_pages.py`：檢查 DocC／ChangeLogKit 入口、根首頁 project 連結、project 內根路徑連結、相對連結目標與 ChangeHistory 頁；在 Pages 上傳前失敗即停止。
- `AV_LAG.md` 加入分類設定，避免新文件只存在 repo 而不出現在靜態站。

## 2026.11.08 16:50 AV Lag 持久化與長場次分段

- 新增 `AVLagReportStore`：可選保留最近 5 場，停止時原子寫入 Application Support；以 session 分組，總量約 50 MiB。
- 新增長場次分段：1／2／4／8 小時（預設 4）可選；8 小時以上拆成子檔但報告頁仍按 session 分組；每段保留 `segmentIndex`、`segmentStartedAt`、`segmentEndedAt`、`inProgress`。
- 預設仍是只保留本次記憶體、4 小時最新區間；未開分段時超限標記 `truncatedBefore`。
- 新增 AV Lag 儲存設定頁：保存模式、長場次分段、段長、清除已保存場次；設定納入非敏感備份。
- 報告頁新增最近場次與分段清單；App 進背景會保存目前未完成 segment，降低被系統終止時的損失。
- 最近場次支援單場刪除：左滑確認後刪除該 session 的所有分段，不會只留下孤兒 segment。

## 2026.11.08 16:30 記憶體歸因、停止後釋放與 byte 上限

- 歸因：`[Memory]` 新增 `mallocInUse`／`mallocAllocated`、`logBuffer` 筆數與 bytes；`[IdleResources]` 新增 UI log、AVLag、StreamDiagnostics 快取計數。用來分辨 App heap 與框架／壓縮頁，不再只看 footprint。
- 釋放：新增 `MemoryRelief`，在 `capture.finished` 與 `didReceiveMemoryWarning` 呼叫 `PIPService.releaseNonCriticalMemory`、縮減 UI／傳輸 log 緩衝；記憶體警告時額外縮 AVLag 並清 URLCache。檔案日誌不刪除。
- byte 上限：`LogBuffer` 2 MiB（仍保留 5000 筆上限）、`LogModel` 1 MiB、`AVLagModel` 2 MiB／2,880 筆；記憶體壓力下縮到 512 KiB。`AVLagModel` 仍只在記憶體，重啟即清空。

## 2026.11.08 16:22 診斷匯出新增上次前景到背景

- `AppSession` 現在在前景 active 時記錄起點、進背景時保存「上次前景 active → 背景」區間到 UserDefaults；程序重啟後仍可選取。
- 診斷匯出新增「上次前景到背景」與「本次前景到現在」範圍；前者取上次 active 到進背景，後者取目前 active 起到按下產生時，兩者前後各留 1 秒以包含邊界日誌。回到前景後可用後者排除先前的背景期間與舊雜訊。
- 16:00–16:20 的停止後記憶體觀察：capturePhase=idle、driver／lease 已釋放、PiP 未啟用，footprint 仍約 134–146MB（pre-capture 28.6MB）；16:19:41 甚至 internal 9.5MB／compressed 125.4MB，代表大部分是壓縮／非活躍頁，不是 CPU 活動或 PiP pool（0.69MB）。仍需冷啟動基準與子系統 A/B 才能判定保留來源。

## 2026.11.08 16:16 背景斷流與 LiveActivity 診斷

- 2026-11-08 15:58:49～16:00:36 的診斷顯示 App 在背景整個被暫停約 107 秒：`[IdleResources]` 30 秒週期中斷、`CaptureCallbacks` 空窗 98.3 秒、`encoderInput inFPS=0 inputIdle≈98.3s`；之後 RTMP 才收到 `Connection reset by peer`。這是 98 秒沒有媒體後伺服器重置，不是 encoder／RTMP 先壞。
- 新增 `[AppEnvironment]` 日誌：啟動與背景／前景轉換時記錄 `UIBackgroundModes`、`isIdleTimerDisabled`、`protectedDataAvailable`；用於確認簽名後 plist 是否仍保留 `screen-capture`，以及鎖定／背景狀態。
- SCK 擷取期間設定 `UIApplication.shared.isIdleTimerDisabled = true`，finish 時還原原值；這只能避免前景自動鎖定，不能保證背景無限續跑。
- `startStreamActivity` 的清理訊息由「重新啟動前清理」改為「建立新活動前清理」；15:31 的第二次啟動是前一次串流 15:26 結束後的新串流，不是 App 重啟。

## 2026.11.08 14:22 退役無引用的方向鎖定偵測器

- 移除 App 原始碼中的 LockDetect.swift／StableLockRotationDetector；主頁入口已移除，確認無剩餘呼叫。
- 原檔移入本機 .build/cleanup-hold 保留區並記錄還原清單，不影響其他方向與旋轉處理。
- 專案結構與差異空白檢查通過；未執行 Xcode 建置。

## 2026.11.08 14:19 清理舊方向通知與無引用本地化

- 移除 orientationChanged 的通知註冊與僅印出棄用訊息的處理分支。
- 清除 home.direction、home.landscape、home.portrait、home.lockDetection 四組已無引用的繁中／英文／日文翻譯。
- DeviceMotin 同名回呼屬性及其他旋轉實作保留；JSON 內容核對、Swift 語法與差異空白檢查通過。

## 2026.11.08 14:17 移除主頁舊方向控制入口

- 移除 ReplayKit 控制區的橫向／直向按鈕與設備方向鎖定偵測開關，清除專用頁面狀態，不再由此頁啟動 CoreMotion 監測。
- 保留暫停畫面、既有旋轉處理、通知實作及其他元件，本次僅清理兩組主頁入口。
- Swift 語法與差異空白檢查通過；主頁實機顯示待驗收。

## 2026.11.08 14:08 建立共用音訊控制設定與拆分回報模型

- 新增 AudioControlSettings，統一兩種來源的音量範圍與 ReplayKit 快照 schema 2；Mic 增益納入串行套用及確認。
- 修正已建立 AudioEngine 未收到 Mic 增益更新；App 額外增益退場為固定 1 倍，保留舊偏好並提示。
- 音量回報模型從畫面拆分，通知集中到 AudioControlCoordinator；ScreenCaptureKit 額外 Mic 增益標示未支援。
- 補共享設定編解碼／範圍測試與驗收說明；語法與專案結構檢查通過，完整 CI 與實機驗收待執行。

## 2026.11.08 14:02 ReplayKit 音量成對同步與套用確認

- 修正讀取 RTMP 配置時將合法靜音 0 改回 1 的問題，配置讀取不再改寫音量偏好。
- App／Mic 改由單一工作取得快照並一次更新 Mixer，避免並行讀改寫互相覆蓋；通知合併，五秒補查支援漏通知與重連。
- 加入 session／套用版本回覆，主 App 顯示等待、成功、過期與同步失敗；失敗保留目前音量。
- 補回覆順序回歸測試與控制流程驗收文件；Swift 語法檢查通過，完整 Xcode 測試與兩種安裝模式實機驗收待 CI／測試。

## 2026.11.08 05:28 音量表統一刻度與 ScreenCaptureKit 增益套用回報

- 修正線性百分比搭配對數長條造成誤讀，來源／估算表統一 −60…0 dBFS，增益顯示 dB 與靜音。
- 增加 session 隔離的 Mixer 設定套用回報；調整後分軌音量明確標為估算，不冒充實測。
- 補刻度與舊 session 回報測試、[量測語意與實機驗收](development/AUDIO_VOLUME_METER.md)。Swift 語法檢查通過，Xcode 測試及實機音量驗收待執行。

## 2026.11.07 21:30 A/V 內容延遲診斷與裝置頁入口

- 問題：使用者用 PiP 固定直播計時器量到 2:22 的影片在 audio 8105.5s 正確、video timer 只有 8100s，內容落後約 6 秒；曲線呈 38／76／94／116／133／141 分鐘的階梯，不是平滑音訊漂移。既有日誌有 FPS、PTS 回退與吞吐量，但缺少「這一格畫面有多舊」。
- 變更：新增 `AVLagDiagnostics`，在 SCK 回呼記錄 `videoContentAge = arrival - sourcePTS`、回呼到 worker 的 queue age、加工延遲、來源 PTS 差與 `CaptureMailbox` 最舊樣本年齡；超過 1 秒或階梯事件即時寫 `[AVLag]`，一般每 10 秒一筆。
- 新增 `AVLagModel`／`AVLagReportView` 與裝置資訊頁 A/V Lag 入口；報告每 5 秒取樣，可複製／分享 schema 1 JSON，供回放 retime 工具交叉比對。序列不會自動改寫播放檔案。
- 注意：PiP 計時器可作內容時鐘，但若只有 overlay timer 落後，不能直接推論整個 game content 落後；仍需遊戲內事件與 audio 對照。PiP A/B 與主執行緒 hitch 量測列為下一步。

## 2026.11.07 17:35 App 圖示切換錯誤診斷

- KSign 相容：release IPA 本身有 `CFBundleAlternateIcons.PersonalIcon`，但 KSign 只認檔案形式的圖示，會讓安裝後的 alternates 空白。新增 `Scripts/add_legacy_alternate_icons.sh`，在未簽名 archive 產生 IPA 前，把 `PersonalIcon` PNG 複製進 App，並在 `CFBundleIcons`／`CFBundleIcons~ipad` 的 `PersonalIcon` 補上 `CFBundleIconFiles`；`CFBundleIconName` 與 Assets.car 保持不變，iOS 仍用 asset catalog。這是簽名工具相容層，不是 `-54` 重複 bundle ID 問題的解法。
- 圖示切換狀態卡住：`setAlternateIconName` 的 completion 可能沒有回來，導致 `isChanging` 永久為 true；預設列在 `selectedName == nil` 時也被 disable，無法重新觸發。改為 8 秒 timeout、記錄 start／completion／current、預設列永遠可重試；若主畫面圖示已變但 `alternateIconName` 仍為 nil，屬系統快取或同 bundle ID 衝突，App 只能提示重啟／重裝。
- 圖示勾選停在預設列：completion 成功時先以請求的 `name` 更新 `selectedName`，診斷刷新改為不覆寫選取；timeout 後再延遲對帳一次。避免系統 `alternateIconName` 晚於 completion 更新時，勾選仍停在預設。
- 文案修正：不再說「執行環境不允許」；改為說明 KSign 等簽名工具指定自訂圖示時會覆寫／停用 App 內建切換，內建圖示只是備用選擇，要用 App 內切換就不要在簽名工具指定自訂圖片。

- 追加觀察：LiveContainer 內若有兩個同 `CFBundleIdentifier` 的 App，`setAlternateIconName` 可能被系統拒絕（OSStatus -54）。把 bundle ID 直接改成 LiveContainer 容器名不是有效解法，會讓目標 App 冒用 host 身分，並出現「檔案不存在」；應使用容器的 clone／唯一 bundle ID，或只保留一份正常安裝的 App。
- 17.4.4（ciRun 42360432381、appRevision 4f3964f）的 release IPA 確認含 `PersonalIcon`；但正常安裝後的診斷仍顯示 alternates 空白。結論：問題發生在簽名／安裝工具改寫 Info.plist，而非 App 建置或 `PersonalIconPreview`。

- 問題：在 LiveContainer 環境下，`supportsAlternateIcons` 為 true、`CFBundleAlternateIcons` 也有 `PersonalIcon`，但 `setAlternateIconName` 回傳 OSStatus `-54`（`permErr`，權限錯誤），原本只顯示系統的模糊描述。
- 變更：切換失敗時記錄 `NSError` 的 domain／code／App bundle 路徑；`-54` 說明改為「簽名工具指定自訂圖示會覆寫／停用 App 內建切換，內建圖示只是備用選擇」，並在圖示診斷加入 `bundlePath`。
- 判定：簽名後的 Info.plist 已正確帶入 `PersonalIcon`，`-54` 是執行容器權限，不是 `PersonalIconPreview` 或 asset catalog 缺失。

## 2026.11.07 05:11 降低週期診斷頻率

- 問題：2.5 小時的診斷檔約 14,166 行，其中約 10,000 行來自每 5 秒一次的 `CaptureSource`、`CaptureVideoProcessing`、`CaptureCallbacks`、`CaptureAudioPipeline` 等例行摘要，不利事後掃讀。
- 變更：擷取週期日誌在啟動 60 秒後，`CaptureSource` 降為 15 秒、詳細管線摘要降為 30 秒；UI 遙測仍每 5 秒更新。HaishinKit `VideoQueue` 由 5 秒改為 15 秒，`publish timeline`／`media timing`／`throughput` 由 10 秒改為 30 秒。
- 例外：錯誤、狀態轉換、`[CaptureAudioAnomaly]` 等事件仍即時記錄；預估同樣 2.5 小時可降到約 2–3 千行。

## 2026.11.07 04:07 音訊逐筆異常日誌與底層時間戳檢查

- 問題：02:58 只知道系統音訊 track0 發生 PTS 回退／discontinuity，聚合日誌無法指出是哪一個 sample；也無法判斷 RTMP timestamp 層是否有補償。
- 變更：`ScreenAudioProbe` 對每個來源音訊 callback 記錄上一筆 PTS；PTS 回退或前進超過 0.5 秒時寫 `[CaptureAudioAnomaly] prevPTS/current/deltaMs/frames/rate`。
- 底層檢查：`RTMPTimestamp.update` 以 wire `updatedAt` 計算來源 delta；音訊使用 `preferredDelta` 時，負向來源 drift 只做每包最多 5ms 的慢速修正（`SlowsLargeNegativeSourceDrift` 測試明定此行為），`allowJump` 只處理正向 >500ms，`sourceRegressions` 僅供診斷，不會觸發 resync。`alignment=observeOnly`、`audioResyncs=0`。
- 尚未改 RTMP timestamp 策略；需先確認 RTMP 音訊來源（mixed）是否真的帶入此 gap，再決定 drop／rebase／補靜音。

## 2026.11.07 01:26 修正圖示診斷 build 參數命名

- 問題：`AppIconDiagnostics` 的初始化參數 `build` 與 `CFBundleVersion` 屬性同名，導致 `build = info["CFBundleVersion"]` 指派到 let 參數而編譯失敗。
- 變更：初始化參數改名 `buildInfo`，屬性仍為 `build`；Swift 語法檢查通過。

## 2026.11.07 01:19 App 圖示診斷辨識 CFBundleIconName 與建置身分

- 問題：17.3.8 IPA 的 PersonalIcon 只有 `CFBundleIconName`，圖示在 Assets.car；診斷卻把沒有 `CFBundleIconFiles` 說成缺 PNG。另 `MARKETING_VERSION`／build 跨 tag 沒遞增，只看版本無法判斷安裝的是哪個產物。
- 變更：診斷新增 iPhone／iPad 的 `CFBundleIconName`，只有 name 時說明「圖示在 Assets.car，缺少獨立 PNG 不代表缺漏」；報告加入 `appRevision`、`buildID`、`ciRun`。測試同步調整。
- 已用 17.3.8 IPA（commit `7a2dae`）確認兩個 device 分支都有 PersonalIcon；若簽名工具的 alternative icons 清單只認 `CFBundleIconFiles`／PNG，空白屬工具限制。
- 待重裝該 IPA 後確認診斷顯示正確 commit 與 PersonalIcon；若仍為空，才判定重簽替換了 Info.plist。

## 2026.11.07 01:12 Socket 送出佇列上限與 encoder 收斂

- 問題：`SocketServer` 的共享 `JSONEncoder` 會被 `queueSend`／`sendTo` 在序列 queue 外呼叫；一般訊息的 `sendQueues` 沒有上限，慢速工具可讓非日誌訊息無限累積；移除連線時保存的 `pendingFailedPayloads` 沒有實際重放路徑，會保留資料。
- 變更：`queueSend`／`sendTo` 移到 queue 內編碼，`dictionary(from:)` 改用區域 encoder；新增 `SocketSendQueuePolicy`（1 MiB／128 筆），超限時記錄並關閉慢連線；外部日誌批次仍使用可丟棄的 `ExternalLogPolicy`。迭代連線時改用快照，移除不會被使用的 pending replay 儲存。
- `SocketSendQueuePolicyTests` 覆蓋邊界、超限與負值；Swift 語法檢查通過。Apple 慢速工具、關閉連線日誌與 `@unchecked Sendable` 全面稽核仍待驗收。

## 2026.11.07 00:55 診斷匯出新增本次啟動範圍

- 問題：診斷匯出只有今天／最近一小時／自訂，無法保證只包含本次程序的日誌；App 啟動也沒有專屬標記。
- 變更：App init 先寫 `[AppSession] launch id=... startedAt=...`；匯出新增「本次啟動到現在」並設為預設，以 `AppSession.launchDate - 1s` 為起點（涵蓋秒精度時間戳），同時顯示本次啟動時間。
- 待實機確認：重新啟動後匯出只含本次啟動、包含 launch marker，且不含前一程序；背景返回不改變本次啟動時間。

## 2026.11.06 23:57 DocC 只在文件相關變更時重建

- 問題：DocC workflow 對任何 `*.swift` push 都啟動 12 分鐘以上的 macOS docbuild，即使只是實作內容變更，沒有動到文件註釋或公開 API。
- 變更：新增 `changes` preflight job，只在 `.docc`／xcodeproj／Package.resolved／DocC 腳本變更，或 Swift diff 含 `///`／`/**`／`public`／`open`／`@_spi`／新增刪除檔案時執行 `documentation` job；手動觸發一律執行。
- 取捨：公開 extension 內未標 `public` 的簽名變更可能被視為實作變更而跳過；需要時用 workflow_dispatch 重建。預期節省大部分純實作 push 的 runner 時間。

## 2026.11.06 23:52 修正樣本管理空狀態的 iOS 17 API

- 問題：`PresetManagementView` 使用 `ContentUnavailableView`，但 App deployment target 是 iOS 16.6，CI 編譯失敗。
- 變更：改用 iOS 16 可用的置中圖示＋標題＋說明 VStack，不再需要對整個管理頁加 `@available`。
- Swift 語法檢查通過；實機畫面待確認。

## 2026.11.06 23:47 App 圖示診斷補版本與 CFBundleIcons 狀態

- 問題：iPad 診斷只顯示空的 alternates，無法區分是舊建置、重簽換掉 Info.plist，還是 asset catalog 沒有帶入。
- 變更：診斷報告加上 version／build／bundle／UIDeviceFamily，以及 `CFBundleIcons`、`CFBundleIcons~ipad` 是否存在；說明分開處理「整個 key 不存在」「有 key 但沒有 PersonalIcon」「有宣告但缺 PNG」。
- 目前 CI archive 已有 PersonalIcon；裝置端若整個 key 都不存在，應先確認安裝的版本與重簽後的 Info.plist，再談 supportsAlternateIcons。
- 待安裝含替換圖示的新建置後比對版本與 presence。

## 2026.11.06 23:45 RTMP 樣本可編輯名稱與網址

- 問題：使用者樣本建立後只能刪除重建，無法修正顯示名稱或 RTMP 網址。
- 變更：「我的樣本」改為管理清單，點一筆可同時編輯名稱與 URL，向左滑刪除；快速套用仍保留在原本選單。
- 更新會保留原 id 與備註；名稱／URL 驗證與重複檢查沿用既有規則，失敗留在表單顯示錯誤，不會部分寫入。
- `RTMPPresetStoreTests` 新增就地更新、持久化、重複與無效 URL 的測試。
- 待實機確認管理清單、編輯儲存與刪除後選單同步。

## 2026.11.06 23:42 釐清 RTMP 樣本名稱欄位

- 問題：「存為樣本」對話框只寫「名稱」，又預填 host，看起來像在編輯 URL。
- 變更：欄位與說明改為「樣本顯示名稱」，明示只保存 RTMP 網址、不會包含串流金鑰；三語字串同步更新。

## 2026.11.06 22:06 包體內容與排除清單摘要

- 問題：原本只把開發檔加總成一個分類，無法直接看出哪些多餘檔案被包進去、哪些預期排除的檔案已正確消失。
- 變更：`inspect_app_bundle.py` 新增「套件內容」與「預期排除清單」；`--expect-excluded` 讀取 `Scripts/package_exclusions.txt`（18 項），逐項列出 ✅ 已排除／❌ 仍包含。任何 `.py`／`.bak`／`.edit`／`.swift`／`.new`／dotfile 被包含，或預期排除項目仍存在，CI 會失敗。
- `AudioProcess.swift.new` 與 `.last_build` 已加入 target 排除；CI 的 archive 與最終 IPA 檢查都使用同一份清單。
- 待下一次 archive 驗證 18 項排除狀態與報告內容。

## 2026.11.06 22:02 修正 CI 圖示檢查誤判並排除殘留開發檔

- 問題：新的 archive 圖示檢查要求 `CFBundleIconFiles` 與獨立 PNG，但 Xcode 的 asset catalog 產物是 `CFBundleIconName` + Assets.car，導致正常 archive 被判定失敗；報告另顯示 `AudioProcess.swift.new` 被包進 ReplyKIT.appex。
- 變更：`inspect_app_bundle.py` 接受兩種標準形式：`CFBundleIconName` + Assets.car，或 `CFBundleIconFiles` + 對應獨立 PNG；缺少 Assets.car／PNG 才失敗。更新對應測試與文件。
- 把 `AudioProcess.swift.new` 加入 ReplyKIT target 的 membership exceptions；包體分類也把 `.new` 視為開發用檔案。
- 待下一次 archive 驗證圖示檢查通過、App 圖示仍待實機確認 `supportsAlternateIcons`。

## 2026.11.06 21:34 Archive 不取消進行中建置

- 問題：Archive workflow 使用 `cancel-in-progress: true`；新推送建立新 tag 時，會取消已跑約 24 分鐘、接近完成的舊 archive，浪費建置時間且可能留下已建立但沒有 Release 的 tag。
- 變更：archive 的 concurrency 保留 `archive-<branch>` 分組，但改為 `cancel-in-progress: false`；進行中的建置完成並發布，新觸發排隊，GitHub 只取代較舊的 pending。
- 取捨：最新版本要等目前建置結束才開始；若之後需要更早切換，可再加「啟動前檢查是否已被新 tag 取代」的 preflight，而不是中止已開始的 archive。

## 2026.11.06 21:26 PiP 文字顏色可調與次要提示預設提亮

- 問題：次要提示使用 `UIColor.lightGray`，在黑色 PiP 上偏暗；主要聊天與次要文字也無法由使用者調整。
- 變更：次要提示／次要聊天預設改為 `#DBDBDB`，主要聊天維持 `#FFFFFF`；新增 `pipMainTextColor`、`pipSecondaryTextColor` 兩個 `#RRGGBB` 偏好與 PiP 排版頁的 ColorPicker。
- 顏色只套用到 PiP 聊天與次要提示；狀態列、現在時間、贊助覆蓋維持固定色。聊天圖層會就地更新，不需重建佇列；次要有頭貼時仍保留頭貼與頁碼配置。
- 顏色偏好納入設定備份（非敏感），`HexColorTests` 覆蓋格式解析與 round-trip。
- 待實機確認 ColorPicker、即時套用與不同背景下的對比。

## 2026.11.06 20:59 PiP 精簡版面上緣留白

- 問題：隱藏控制列的精簡版面把計時列放在 `y = 12`，在 PiP 大圓角旁看起來太貼上緣。
- 變更：精簡模式整組下移 8pt：狀態列 20、現在時間 42、提示 62、聊天頂距 84；左緣仍為 `contentLeading`，不單獨把計時器往右，避免破壞資訊列對齊。仍比一般模式多保留 16pt 給聊天。
- 待實機確認不同視窗比例下的上緣與圓角視覺。

## 2026.11.06 20:51 RTMP 樣本改為 JSON 與個人樣本

- 問題：快速選擇只有兩個硬編碼端點，新增樣本必須改 Swift；使用者無法保存自己的常用 URL。
- 變更：內建樣本移到 `liveAPP/RTMPPresets.json`（只含名稱與 RTMP／RTMPS URL，不含金鑰），讀取失敗時退回原本兩個端點。使用者樣本存 `rtmpUserPresets`，選單分成內建／我的，可將目前 URL 存為樣本、刪除、匯入與匯出 JSON。
- 匯入接受 `{version,presets}` 或單純陣列；驗證 URL、名稱長度與上限 50 筆，重複的名稱＋網址會略過，匯入項目一律使用新的使用者樣本 id。
- 切換到不同 host 的樣本時清空串流金鑰並提示重新輸入；金鑰永遠不寫入樣本或樣本 JSON。
- `rtmpUserPresets` 納入設定備份（非敏感），可隨完整設定還原。
- 待實機確認檔案匯入／匯出、選單分組與不同 host 的金鑰清理行為。

## 2026.11.06 20:37 PiP 次要提示分段與可選頭貼

- 問題：次要提示維持單行截斷，長文字後半看不到；且無法選擇是否顯示頭貼。
- 變更：summary 模式把提示切成最多 4 頁、每頁 2.5 秒，右側顯示頁碼點；超過 4 頁截斷加省略號。換頁沿用 1 FPS 時鐘，不提高 PiP 渲染 FPS。
- 新增 `pipNoticeAvatar`（預設關閉）：開啟時頭貼排在文字左側，頁寬與頁數重新計算；沒有頭貼自動省略。設定變更會立即重算目前提示。
- 預覽與訊息測試頁同步顯示頭貼與分段結果。
- 待實機確認頁數／速度、頭貼載入，以及提示與時間列、聊天之間不重疊。

## 2026.11.06 20:17 備份輪替、PiP 診斷頻率與 SCK 收尾超時

- 問題：舊的 `settings-latest.json` 若損壞或超過 2 MB，`SettingsBackupStorage.save` 會在輪替時拋錯，之後的自動備份永遠寫不進去；PiP 每分鐘寫一筆效能摘要，長場次日誌過度膨脹；SCK 停止時任一 await 卡住，UI 會一直停在「正在停止擷取」。
- 變更（備份）：`save` 寫入前檢查 2 MB 上限；舊 latest 無法讀取時不再中斷，改為整檔移到 `settings-previous.json` 後再寫新檔，損壞的舊檔不會永久阻塞備份。新增 oversized latest 回歸測試。
- 變更（備份頻率）：`SettingsBackupManager` 新增 `needsSave`；只有收到偏好變更才在節流到期或背景時重新 capture。前景／背景反覆切換但設定沒變時直接跳過，不再每次背景都做一次完整備份檢查。
- 變更（PiP 診斷）：一般摘要改為每 5 分鐘；只有 renderFailures 或 backpressureSkips 才在滿 1 分鐘時提前回報。排程延遲尖峰不再單獨觸發摘要。
- 變更（SCK）：`finish` 對 diagnostics、operation、publishing、stopCapture、錄製完成與管線停止加上有上限的等待；每一步記錄 `finish stage=... elapsedMs=...`，超過上限仍繼續收尾並回到 idle，不再無限停在 stopping。
- 待實機確認：備份在損壞檔後能恢復、PiP 摘要頻率、SCK 停止（含啟動中取消與錄製收尾）的最後狀態與新 stage 日誌。

## 2026.11.06 19:31 補強替換圖示相容性與包體產物檢查

- App 圖示頁新增宣告診斷、複製與變更時日誌，區分 iPad 宣告缺失及系統拒絕。
- PersonalIcon 補明確 iPhone／iPad 尺寸，CI 檢查產物圖示檔案宣告與 PNG，失敗保留報告。
- 新增 IPA 分類大小與最大檔案報告。實際比較 17.2.8／17.2.9，增量約 97.8% 位於 Assets.car。
- 排除 16 個開發腳本與備份檔的 App target 成員資格，不刪除來源。
- Python 產物檢查測試、YAML 解析、專案結構與 Swift 語法檢查通過；新版圖示切換及編譯結果仍待 CI／實機驗收。

## 2026.11.06 12:11 新增設定備份與還原，公開本地錄影目錄

- 工具新增備份入口；偏好變更合併保存至 Documents/ConfigBackups，保留最新與前一份，顯示成功時間及分享入口。
- 白名單涵蓋共享與主 App 偏好，排除執行狀態；敏感網址／金鑰／配置庫僅手動選擇匯出。
- JSON 匯入驗證後預覽，保存還原前快照，於下次完整啟動套用，避免服務設定不同步。
- 本地錄影由 Application Support 搬至 Documents/ScreenRecordings；不覆蓋新庫，失敗保留舊路徑供分享並提示。
- 補側載到期前搬移設定、壓縮影片與錄影提醒、使用文件及回歸測試；Swift 語法檢查完成，Xcode／實機驗收待執行。

## 2026.11.06 11:58 新增內建 App 圖示切換

- 工具的外觀設定新增 App 圖示入口，提供預設與 Exp2「個人精選」。
- Debug／Release 宣告 PersonalIcon 替換資源；原稿留在 Artwork，不重複打包。
- 選用標記讀取系統狀態，加入切換中、失敗及不支援提示，並補繁中／英文／日文。
- 已檢查 Swift 語法、資源 JSON 與差異空白；Xcode 編譯及 iPhone／iPad 實際切換待 CI／實機驗收。

## 2026.11.06 07:15 模擬器開機加入候選順序與重建 fallback

- 問題：CI 選到 iPhone Air（iOS 27.0）後 `simctl bootstatus` 超過 5 分鐘；selector 用 `max(...)` 會用名稱字典序挑，像 Air 這種非常規機型可能先被選中，而且沒有備援。
- 根因：選機與開機是兩步、單一 UUID 決策；沒有嘗試其他裝置，也沒有標準機型偏好。
- 變更：selector 輸出排序過的候選清單（SDK 同版本優先、已開機優先、iPhone 17/16/15 等標準機型優先），並輸出所屬 runtime 與可建立的 device type；workflow 逐台嘗試前兩台（每台最多 120 秒），都失敗再用該 runtime 建一台全新 iPhone 開機（240 秒）。
- 開機步驟上限 10 分鐘、單元測試步驟上限 20 分鐘；整個 job 仍是 40 分鐘，避免 fallback 吃掉後續測試時間。測試步驟改用實際開機成功的 UUID。
- 回歸測試涵蓋標準機型優先、候選排序與 device type 選擇。
- 待下一次 CI 驗證 runner 上現有裝置的開機狀況與 fallback 流程。

- 問題：版本條目的 `localizedDescription` 原本退回 App 層介紹，AltStore 的 What's New 會顯示整個 App 說明，不是這次更新內容。
- 根因：合成腳本沒有接收版本說明的入口。
- 變更：`update_altstore_source.py` 新增 `--notes`／`--notes-file`，內容寫入 `versions[].localizedDescription`；`main.yml` 在合成前用最近 10 筆 commit 產生 `build/altstore-notes.txt` 並傳入。
- App 層 `localizedDescription` 維持商店頁完整介紹；`news[]` 不用於版本更新說明。
- 待下一次 Release 檢查 AltStore 顯示的多行說明與換行。

## 2026.11.06 06:52 PiP 計時器併列與精簡版面開關

- 問題：計時器單獨置中在頂端，和左側「直播中／人數」、下方「現在時間」沒有共同對齊線，看起來像漂在上面。
- 根因：計時器獨立一行且置中；控制列避讓只套用在其他內容。
- 變更：計時器併入「直播中／人數」同一列並靠左；系統控制列顯示時整列從 `controlSideInset` 起、右界同步留白，控制列全隱藏時從 `contentLeading` 起用滿寬度。
- 新增「隱藏控制列時將資訊列上移」（`pipCompactOverlay`）：僅在「隱藏關閉與返回按鈕」開啟時有效，狀態列 36→12、現在時間 58→34、提示 78→54、聊天頂距 100→76；切換時會立即重排既有聊天訊息。
- 預覽同步：控制列全隱藏時不再畫系統按鈕佔位圈，並反映精簡版面。
- 待 Apple CI 與實機確認計時列對齊、控制列顯示時的避讓，以及精簡模式切換後的聊天重排。

- 問題：unit tests 選到 iOS 27.2 的 iPhone Air，但該 runtime 路徑不存在，`xcodebuild test` 直接失敗；`devices.json` 仍把裝置標成 available。
- 根因：selector 只看 `devices.json` 的 `isAvailable`，沒有使用 workflow 已抓好的 `runtimes.json`，且硬性只選 iOS 27，沒有安裝狀態與 SDK 版本的取捨。
- 變更：selector 只接受實際安裝且可用的 iOS runtime（含路徑存在檢查）；優先選與建置 SDK 同版本的 runtime，其次 iOS 27，最後才退到最新可用的其他 iOS runtime。`unit-tests.yml` 會把 `xcrun --sdk iphonesimulator --show-sdk-version` 傳給 selector。
- 補回歸測試：殘留但 runtime 已移除的裝置、runtime 路徑不存在、SDK 版本優先、26.x fallback。
- 待下一次 CI 驗證實際 runner 的 runtime 清單與選機結果。

- 問題：測試頁只有純文字表情，沒有頭貼可驗證；長訊息捲動時聊天邊緣遮罩每幀重建，動畫明顯變卡。
- 根因：頭貼只支援 URL 載入；`updateChatEdgeMask` 在每個動畫 tick 都做整層 filter、CATransaction 與遮罩指定，且沒有續段時仍掛著遮罩做 offscreen 合成。
- 變更：`addMessage`／`snapshotMessage` 支援直接傳入 `UIImage` 頭貼，測試頁新增「測試頭貼＋表情」並同步顯示在預覽；沒有頭貼時不再建立空的 avatar layer。
- 訊息寬度不再固定預留 avatar＋gift：無頭貼訊息左緣改為 `contentLeading`，右側只扣實際存在的禮物與 `contentTrailing`，避免提前換行與右側空白；無頭貼訊息也不再被永遠開啟的遮罩淡出名字。
- 邊緣遮罩改成只在幾何（高度、頂距、收邊高度）變動時更新，並在沒有需收邊的續段時把 `container.mask` 設回 `nil`；`tickAnimation` 不再每幀更新遮罩，只在開始淡出與重新排版時更新。
- 待 Apple CI 與實機確認頭貼測試、長訊息／多段訊息動畫流暢度及頂端收邊時機。

- 問題：每次 Release 都要手動改 `AltStoreTest.json` 的 `downloadURL`、`size`、`date` 與版本，容易出現 tag 與版本指向不一致。
- 根因：建置流程沒有把封存後的 `Info.plist` 版本與實際 IPA 大小帶回來源檔。
- 變更：`main.yml` 的 build job 讀取 `CFBundleShortVersionString`／`CFBundleVersion` 與 IPA 位元組數；以版控中的 `AltStoreTest.json` 為樣板，用 `Scripts/update_altstore_source.py` 合成 `build/AltStoreTest.json`，附在該次 Release。樣板不被改寫，CI 不產生 commit。
- AltStore 來源固定指向 `releases/latest/download/AltStoreTest.json`，版本鍵 `(version, buildVersion)` 會就地更新，最多保留 10 筆，並保留 App 層描述與 `minOSVersion`。
- `version`／`buildVersion` 仍忠實反映 App 二進位；AltStore 是否提示更新取決於這兩個值是否遞增，CI 不自動改版號。
- 待下一次實際 Release 驗證 asset 上傳與 AltStore 端顯示；首次產生 asset 前，舊的 raw main 來源仍是唯一入口。

## 2026.11.06 04:13 修正scrollSpeed初始化順序錯誤

**類型**: 修復 · **檔案**: `liveAPP/PIPContent.swift`

### 問題

在呼叫updateChatEdgeMask()前需要先完成所有需要初始化的值

### 修改

先初始化完所有屬性 含scrollSpeed在呼叫
updateChatEdgeMask()

---

## 2026.11.06 03:57 PiP 聊天續段退場收邊

- 聊天圖層新增頂部裁切遮罩；頂部為續段或正在淡出時使用 12 點漸隱，完整新訊息保持清晰，時間與狀態圖層不受影響。
- 保留逐段閱讀及原有退場時機，不直接刪除整筆訊息；修正無效淡出時長可能產生 NaN 透明度的風險。
- 語法與差異檢查通過；長訊息尾段、圖片／表情及動畫結束後快取畫面待實機驗收。

## 2026.11.06 01:48 測試 PiP 生命週期改由服務管理

- 移除測試頁離開自動停止，以服務發布的啟動中／顯示中狀態維持跨頁操作；主 PiP 頁新增停止測試播放器入口。
- 正式與測試服務啟動前互斥；系統關閉／啟動失敗只清理測試服務，修正誤停正式 PiP。啟動超過 15 秒仍無成功回呼時清理。
- 測試渲染統一主佇列，舊送幀以世代拒絕；移除逐幀日誌。語法檢查通過，跨頁與系統關閉待實機驗收。

## 2026.11.06 01:37 PiP 預覽方向與緊湊排版修正

- 預覽入口將 UIKit 座標轉為正式 renderer 所需座標，修正聊天、時間及贊助整幀上下翻轉。
- 系統按鈕示意直徑由 44 調為 24，內容左右避讓獨立設定；計時頂部置中，狀態／人數另列，聊天頂距由 120 縮至 100。
- 重連取代狀態文字，次要提示維持聊天上方固定區；長狀態截短、人數簡寫、時間限制內容寬度。
- 測試頁重整為預覽、PiP 控制、訊息及獨立播放器；測試不再觸發 TTS，未啟動時只更新預覽，運行中沿用聊天室。
- Swift 語法與差異檢查；方向、系統按鈕避讓及不同 PiP 尺寸待實機確認。

## 2026.11.05 22:57 PiP 預覽改走正式繪製管線

- 問題：上一階段只統一了時間疊加，聊天與贊助預覽仍是 SwiftUI 示意元件，與 runtime 各維護一套版面。
- 根因：預覽沒有重用 `PIPServiceMessages` 與廣告繪製，字級、座標與行距都可能分岔。
- 變更：抽離 `PIPAdOverlayRenderer`；新增 `PIPPreviewFrameRenderer`，在同一張 300x200 畫布上依序繪製聊天快照、時間疊加與贊助覆蓋。預覽改為顯示這張正式輸出，只保留系統按鈕佔位圈；`PIPServiceMessages` 新增不觸發動畫與 `PIPService` 全域狀態的快照模式，並可直接指定字級。
- 不再另開 Swift Package：預覽與 runtime 同在 `liveAPP` target，共用檔案即可，避免多一層 access 邊界。
- 待 Apple CI 與實機確認預覽與 PiP 實際畫面一致、快照不影響正式聊天狀態。

## 2026.11.05 22:45 PiP 資訊列整合與預覽共用繪製

- 問題：計時／直播／觀眾那一列留在系統按鈕帶內，和下方的現在時間、提示左右錯開且距離過大，視覺上像兩塊；排版預覽又用 SwiftUI 重畫一套時間列，容易和實際輸出分岔。
- 根因：狀態列仍以「按鈕之間的空檔」排版，且預覽與 runtime 各自維護座標與字級。
- 變更：計時列下移到 `y = 58`，與現在時間（`y = 78`）、提示（`y = 99`）統一 `x = 12` 左緣；聊天安全頂距改為 `120`；狀態列寬度改用內容邊距，過寬時先省略時鐘圖示、再省略觀眾數。
- 時間疊加抽成 `PIPTimeOverlayRenderer`，runtime 與排版預覽共用同一份繪製；預覽直接顯示其輸出，不再用 SwiftUI 重畫時間列。聊天與贊助預覽仍為示意元件，列為下一階段統一。
- 待 Apple CI 與實機確認新的 Y 間距、預覽與實際畫面一致、狀態列在長文案下的取捨。

## 2026.11.05 21:56 PiP 安全區重排與控制列選項

- 問題：現在時間置中、單行提示固定在 `x = 12`，兩者 x 不一致；系統關閉與返回按鈕出現時，計時列與現在時間尾端會被遮住。
- 根因：時間列座標各自寫死，沒有系統控制列的保留區；預覽也未畫出按鈕佔位。
- 變更：新增 `PIPOverlayLayout` 共用安全區（帶高 56、左右 56、內容左緣 12、現在時間 `y = 60`、提示 `y = 84`、聊天頂距 104）；計時列限制在兩顆按鈕之間，必要時先省略時鐘圖示、再省略觀眾數；runtime 與排版預覽共用同一組常數，預覽補上控制鈕佔位與提示行，現在時間與提示統一左緣並移到保留帶下方。
- 新增「隱藏關閉與返回按鈕」（`pipHideSystemControls`）：預設維持 `controlsStyle = 1` 保留關閉／返回；開啟後改用私有的 `2` 隱藏全部控制。關閉出口固定在 App 的「子母畫面」頁「停止 PiP」，會實際呼叫 `stopPictureInPicture()`，不會留下關不掉的視窗。
- 待 Apple CI 與實機確認按鈕遮擋、預覽一致性、控制列即時切換與停止 PiP。

## 2026.11.05 21:27 移除啟動PIP禁用進階PIP訊息與畫面測試設定

**類型**: 修復 · **檔案**: `liveAPP/PIPView.swift`

### 問題 - 啟動PIP後 會造成進階訊息與畫面測試 被停用

### 修改 - 移除停用規則

---

## 2026.11.05 20:29 LiveActivity 改為預設關閉

- 全局開關未設定時預設關閉，已明確啟用的偏好保留；設定頁與服務預設一致。
- 開播入口關閉時不呼叫活動啟動；管理器仍再次檢查偏好。直播中停用會結束活動，不影響推流。

## 2026.11.05 20:18 PiP 一般刷新與次要訊息設定

- 聊天室 PiP 新增 1／2／5 秒時間刷新與「降低聊天室動畫頻率」選項；保活更新仍獨立管理，新訊息提早刷新。
- 時間文字依更新週期快取；靜態聊天圖層只保留一張快取，內容／尺寸變更與動畫時失效，停止時釋放。
- 時間列上移、移除額外黑底；次要訊息可一般顯示、單行提示或隱藏，預設單行只保留最新通知約五秒，不推擠主要聊天。
- 新增不受總日誌／PiP 詳細開關限制的本機 PiPPerformance 每分鐘摘要與停止尾段，包含耗時、排程延遲、背壓及快取估計，不轉送遠端。
- 本機語法與差異檢查通過；PiP 圖層方向、不同視窗大小及動畫負載待實機驗收。

## 2026.11.05 20:08 明確區分 RTMP 起始與最新入列紀錄

- 影音 RTMP 時間預設顯示最新入列嘗試、結果與快照取樣時間；首次嘗試及首次成功移入收合明細。
- 分列標示來源 PTS／DTS 與 RTMP 相對 PTS／DTS，說明首筆 0 秒可為正常起點，缺值顯示未提供。
- 保留本機入列不等於伺服器接收的提示；未改動底層時間戳計算。

## 2026.11.05 01:29 LiveActivity 更新週期與設定入口

- 工具／全域設定新增即時動態管理，提供開關與 1／5／10／15 分鐘摘要更新，預設 5 分鐘；偏好不依賴 App Group。
- 鎖定畫面及動態島改由固定開播時間顯示計時，摘要過期時間隨週期調整，結束時凍結計時。
- 更新任務取消立即退出；啟動請求核對世代，避免停止後復活。重連通知即時更新，ScreenCaptureKit 重連保留活動與開播時間。
- 新增設定值驗證測試；本機僅可做 Swift 語法檢查，活動顯示與生命週期待 iOS CI／實機驗收。

## 2026.11.04 16:55 修正壓縮測試準備階段逾時

- 壓縮另存測試改用隨測試 bundle 打包的固定合成 MP4，移除壓縮前額外建立影片的 Writer 等待流程。
- 兩種壓縮模式依序執行，保留原檔逐位元組比對，新增輸出時長與實際影格解碼驗證；未略過壓縮測試。
- 本機檢查樣本格式與 Swift 語法；iOS 實際壓縮結果待 CI 驗證。

## 2026.11.04 16:39 修正日誌匯出入口與 PiP 操作提示

- 診斷匯出改用按鈕開啟獨立 sheet／NavigationStack，避免日誌分頁缺少導航容器時無法進入。
- PiP 未啟動時停用並淡化停止按鈕，運行狀態增加圖示、標題及操作提示，不只依靠顏色。
- 保留近期外部日誌與 CI 修正；本機語法檢查通過，實機點擊與 PiP 狀態切換待驗收。

## 2026.11.04 01:21 修正封存測試的 FileManager 參數標籤

- 問題：`LogArchiveStoreTests` 使用 `setAttributes(_:atPath:)`，CI 編譯失敗並中止整批測試。
- 根因：新增測試誤用 `FileManager` API 標籤，正確為 `setAttributes(_:ofItemAtPath:)`。
- 變更：修正該呼叫；同一編譯批次未再出現其他錯誤，待 Apple CI 重跑確認。

## 2026.11.04 01:05 補外部日誌角色與通道切換測試

- 問題：擴展角色只認批次與健康訊息，漏了 ReplyKIT `sendLog` 的單筆 `log`；切換通道時 `clear`／`stop` 皆非同步，舊緩衝可能被下一個 flush 用新通道送出。
- 根因：角色判定與容量規則散落在 SocketServer 內，無從測試；緩衝項目未記錄產生時的通道。
- 變更：抽出 `ExternalLogPolicy` 與 `ExternalLogSubscriptions` 純邏輯，角色集合納入單筆 `log`；緩衝項目標記通道，flush 只取當前通道項目，舊通道殘留直接丟棄；補 `ExternalLogPolicyTests`。
- 行為不變：無訂閱者仍不累積、單筆 `log` 仍只落本地不轉送；待 Apple CI 與實機多連線驗收。

## 2026.11.04 01:00 修正擴展日誌 I/O 診斷的編譯錯誤

- 問題：擴展日誌封存改寫刪除了 `safeWrite` 與 `ioFailure*` 狀態宣告，卻保留 `recordIOFailure`／`flushIOFailures`，Apple CI 編譯失敗（cannot find in scope）。
- 根因：重構整塊刪除時未檢查仍被方法引用的成員，宣告與實作分離。
- 變更：補回鎖、計數、最後錯誤、排程項目與 60 秒視窗常數；`safeWrite` 已無呼叫端故不還原，全檔確認無殘留引用。
- 待 Apple CI 重跑確認；Windows 環境無法本機編譯。

## 2026.11.04 00:40 外部日誌新增 Socket 訂閱通道

- 保留 HTTP 預設，日誌頁與設定增加通道選擇及訂閱工具數量。
- Socket 一般日誌使用 externalLogBatch；未知連線不接收，擴展訊息連線取消外部訂閱。
- 帶外 diagnostic 改送訂閱工具，排除來源與擴展；補容量門檻、回送忽略與協定文件。
- Apple CI 與多連線實機驗收待完成。

## 2026.11.04 00:31 長播日誌輪替封存與擴展交接

- 主 log.txt 超限後封存完整舊檔，時間範圍匯出包含封存與清理缺口提示。
- 背景連續寫入重用 handle，閒置十秒才關閉；前景取消關檔排程。
- 擴展改不可變批次交接，排他鎖協調發布／匯入／清理，主 App 複製成功才移除交接檔，不再截斷活動檔。
- 設定封存容量與保留期限、補文件與回歸測試；場次索引另待實作，Apple CI 與實機長播驗收待完成。

## 2026.11.04 00:14 補強日誌批次寫入與安全裁切

- 修正提前 flush 舊排程殘留，日誌頁讀取不強迫寫入；背景嘗試落盤關檔。
- 成功才計量；寫入失敗回復後有界重試，超限與回復失敗明確報告丟棄。
- 加入容量上限、分塊校準與有限尾端原子裁切，避免先清空主檔再寫回。
- 補裁切測試與 LOG_PERSISTENCE.md；故障注入、Apple CI 及實機背景驗收待完成。

## 2026.11.03 23:55 新增時間範圍診斷日誌匯出

- 日誌頁支援今天、最近一小時與自訂範圍，產生獨立檔案分享，保留主日誌。
- 固定快照後分塊篩選，保留多行續文，附時區、範圍與解析摘要；遮蔽常見憑證。
- 工作結束清理原始快照，匯出快取保留七天；補文件及回歸測試，Apple CI／實機待驗收。

## 2026.11.03 03:50 手動壓縮色彩策略與實測顯示

- 新增自動、嚴格保留及 SDR BT.709 策略，缺少必要來源資訊時阻止手動策略並顯示原因。
- 壓縮頁分開呈現來源、預計及成品實測色彩，避免自動選項隱藏解析結果。
- 嚴格與 BT.709 成品加入色彩標記驗證；系統品質模式明確交由系統管理。
- 補策略測試與說明；本機語法檢查通過，Apple 建置與實機色彩驗收待完成。

## 2026.11.03 03:45 修正壓縮 API 的 iOS 可用性

- 移除 iOS 不可用的 SMPTE 240M Writer 常數引用，遇到該來源矩陣明確回報不支援。
- 品質預設改用非同步 determineCompatibility 檢查來源與 MP4，取代棄用的 exportPresets 查詢，保留取消檢查。
- 補 240M 拒絕測試；本機語法檢查不涵蓋 Apple SDK 可用性，仍需 CI 建置驗證。

## 2026.11.03 03:38 修正壓縮色彩矩陣映射與不完整設定

- 將來源 YCbCrMatrix#5／#6 正規化為 Apple BT.601 矩陣，不依解析度猜成 BT.709。
- Writer 色彩字典只在三項完整時提供；部分資訊透過解碼影格附件傳遞，未知矩陣明確失敗。
- 補映射回歸測試與診斷；實機 HEVC 匯出、亮暗與色彩驗收待完成。

## 2026.11.03 03:06 補強壓縮輸出設定拒絕診斷

- 平均碼率壓縮記錄工作識別碼、來源格式與色彩、輸出寬高、編碼及 Writer 設定。
- 檢查拒絕時比較不含色彩欄位的設定是否可接受，只作診斷，不自動降級或移除色彩。
- 錯誤明確標示尚未開始編碼，附參數與診斷編號；Apple 平台建置及實機拒絕原因待驗證。

## 2026.10.29 20:36 PiP 保活間隔與操作頁整理

- 保活更新間隔提供 1–60 秒設定，預設 5 秒；共用設定入口並即時重排。
- 修正低 FPS 差距門檻造成間隔變更可能被忽略；保留贊助期間活動頻率。
- PiP 日常頁與進階測試頁拆開，離開測試頁停止獨立測試服務。
- 補 Swift 文件註釋、頻率策略測試及 development/PIP_KEEPALIVE.md；Apple 建置與實機行為待驗證。

## 2026.10.29 20:19 壓縮成品清單與暫存管理

- 工具與壓縮頁加入成品清單，可查看大小、日期、時長，播放、分享及確認後多選刪除。
- 新相簿副本及手動轉碼暫存改為程序專屬目錄；提供前次程序暫存容量與清理，保護目前程序任務。
- 提供清除目前來源，清理失敗寫日誌並保留追蹤；舊版未知用途暫存不自動刪除。
- 詳見 development/COMPRESSED_VIDEO_LIBRARY.md；Apple 平台建置與實機驗收待完成。

## 2026.10.29 07:21 主程序記憶體比較診斷

- 主 App 記憶體基準不再由 ReplayKit 持久化狀態決定；另列最後已知狀態，基準不代表擴展已停止。
- 增加本程序首次採樣、首次擷取前最近閒置採樣及停止後 300 秒觀察；錯過的時點標為 missed，不回填歷史數值。
- ScreenCaptureSource 加入物件建立／析構識別，區分管理器清空引用與物件真正釋放。
- Mixer／編碼器持有量及實機長時間觀察仍待補足。

## 2026.10.29 06:52 區分 ScreenCaptureKit 發布結束原因

- 發布回呼攜帶生命週期原因，區分網路重連、發布失敗與停止發布；不改 PiP 顯示文案。
- Live Activity 未提供原因時使用中性文字，不再一律記為手動結束。
- 兩份 HaishinKit 套件鎖定同步至 `9df0d778`：接入持續連線 60 秒後恢復重試額度與 close 去重；底層 CI 已通過，主 App 建置及實機驗收待完成。

## 2026.10.28 08:29 接入 RTMP 封包與重連修正

- HaishinKit 套件鎖定由 `992412e9` 更新至 `946de4e9`，包含 `dd274027` 的 RTMP 修正。
- ReplayKit 與 ScreenCaptureKit 共用底層修正：續接 chunk 補 extended timestamp、大 CSID 位元組順序修正、新連線重建影音時間基準、重新發布失敗不再誤報重連成功。
- ScreenCaptureKit 日誌白名單補上 `Receive loop ended`；ReplayKit 沿用必要事件入口，接收帶連線世代的接收結束原因；區分接收錯誤、遠端 EOF 與本機關閉，避免舊接收迴圈結束時關閉新連線。
- 底層 CI 已通過；主 App 的 Apple SDK 建置及 Twitch 長時間推流／重連仍待驗收，尚不能認定此次修正已排除 log-62 的首次斷線原因。

## 2026.10.26 23:37 修正 CI 模擬器目的地選取

- 原選取僅依 simctl 可用清單挑最新 runtime，可能選到 liveAPP scheme 不接受的 UUID，導致 xcodebuild exit 70。
- 改為解析鎖定套件後，交叉比對 Debug scheme 相容目的地與 simctl 的可用 iOS 27 iPhone。
- 保存裝置、runtime、目的地與選取結果至 TestResults；查詢及開機步驟各設五分鐘上限。
- 三項 Python 回歸測試通過；實際 Xcode 模擬器測試待 CI 驗收。

## 2026.10.26 23:26 接入手動系統品質匯出與修正 PiP 快捷標籤

- 壓縮頁新增互斥系統品質模式，依來源列出可用 MP4 預設，隱藏不生效的手動參數與容量估算。
- 系統模式支援另存、取消及產物驗證；錄後較小才替換的策略保持不變。
- 主頁 PiP 快捷標籤縮短並增加最小欄寬，避免一般字級下單顆按鈕換行。
- 補系統匯出測試與中文文件；語法與差異檢查通過，Apple CI／實機驗收待執行。

## 2026.10.26 17:15 集中工具入口與統一選片按鈕樣式

- 第五分頁改為「工具」，集中影片分析、壓縮、本地錄影、PiP 操作與 App 設定；保留既有分頁識別與偏好。
- 主頁增加依寬度換行的常用工具入口，PiP 操作與排版設定集中於工具頁。
- 碼率頁「從檔案」移除額外透明度，與「從相簿」使用相同顏色。
- 新入口補繁中、英文、日文；Swift 語法、翻譯 JSON 與差異檢查通過，實機排版待驗收。

## 2026.10.26 17:05 手動壓縮加入播放與自訂參數

- 新增完成影片播放頁，離頁停止並釋放播放器。
- 建議碼率增加套用前後回饋；支援小數 Mbps、快捷值與含音訊的容量估算摘要，預估不縮小時提醒。
- 來源、成品及詳細頁逐音軌顯示取樣率、聲道與估計碼率；未知資料不顯示成零。
- 支援自訂顯示寬高上限、預計輸出尺寸、1…120 FPS 與 AAC 每軌碼率；保持比例、不放大、不補幀。
- 共用轉碼器按旋轉後方向套用尺寸限制，保留原有錄後壓縮預設；補尺寸與旋轉單元測試。
- 驗證：Swift 語法與差異檢查通過；Apple SDK 建置、測試及實機播放待驗收。

## 2026.10.26 04:06 手動壓縮改為完整頁面並支援相簿選片

**類型**: 功能 · **檔案**: `liveAPP/Compression/VideoCompressionView.swift`、`liveAPP/Compression/VideoCompressionModel.swift`、`liveAPP/VideoBitrateView.swift`、`liveAPP/Support/PhotoVideoImport.swift`

### 問題 - 壓縮頁只能從檔案選片，且碼率頁以臨時表單開啟

同一個壓縮頁在錄影詳細頁是推入頁面，在碼率頁卻是 sheet 疊 sheet，並多一個「完成」按鈕；選片也只有 fileImporter，沒有相簿入口。

### 根因 - 兩個入口各自決定呈現方式，且相簿匯入邏輯只存在於碼率頁

### 修改 - 統一推入頁面、加入相簿選片並共用檔案式匯入

- 碼率頁工具列的「壓縮影片」改為 Button 搭配 `navigationDestination` 推入，移除 sheet 與「完成」按鈕，與錄影詳細頁同級；推入期間保留相簿暫存檔，真正離開分析頁才清除。
- 壓縮頁新增 `PhotosPicker`；相簿影片以 `FileRepresentation` 複製到 App 暫存後才選取，避免整段影片進入記憶體；讀取期間停用來源按鈕並顯示進度。
- 相簿暫存副本由 `VideoCompressionModel` 持有，只保留最近一份；換片或改選檔案時刪除。
- 碼率頁的相簿匯入改用共用 `PhotoVideoImport`，不再以 `Data` 一次載入整片。
- `PhotoVideoImport` 需同時匯入 SwiftUI 與 PhotosUI；`PhotosPickerItem` 由 cross-import overlay 提供，只匯入 PhotosUI 會找不到型別。
- 待 CI／實機驗證相簿選片、iCloud 下載與推入導覽。

## 2026.10.26 02:55 改善手動壓縮測試診斷與編碼設定

**類型**: 修復 · **檔案**: `liveAPP/Capture/RecordingTranscoder.swift`、`liveAPPTests/VideoCompressionExportTests.swift`

### 問題 - separateOutputKeepsSourceBytes 在 CI 以 NSCocoaErrorDomain 512 失敗

Swift Testing 只在測試宣告行回報「The file couldn't be saved.」，無法從日誌判斷是建立暫存檔、寫入、移入成品或測試自身的合成影片失敗。

### 根因 - 檔案類錯誤共用同一個出口，且測試影格配置與錄影路徑不同

轉碼器的 Writer 建立、寫入與移檔都把底層錯誤直接重拋；測試以非 IOSurface 緩衝、64×64 合成來源，再以 1 Mbps 目標碼率轉碼，和同一 CI 已通過的錄影路徑（關閉重排序、使用緩衝池）不一致。實際失敗階段尚待 CI 重跑確認。

### 修改 - 錯誤標示階段、轉碼與錄影一致關閉 B 幀、測試改用編碼器緩衝池

- 平均碼率模式關閉 B 幀，與錄影路徑一致；影格時間順序固定，輸出時長驗證較可預期。
- `AVAssetWriter` 建立、開始寫入、寫入樣本、完成、移入成品與取代原檔失敗都包成「階段：原因」，保留 `NSUnderlyingErrorKey`。
- 測試改由 adaptor 的像素緩衝池取得 IOSurface-backed 影格、關閉重排序、改為 320×240 十幀，等待與附加階段拋出具名錯誤，結束後刪除暫存資料夾。
- 尚未取得 CI 重跑結果，實際失敗階段待確認。

## 2026.10.26 02:26 修正手動壓縮頁的硬體編碼能力查詢

**類型**: 修復 · **檔案**: `liveAPP/Compression/VideoEncoderCapabilities.swift`、`liveAPP/Compression/VideoCompressionView.swift`、`liveAPP/Compression/VideoCompressionModel.swift`

### 問題 - CI 編譯失敗：cannot find 'VTIsHardwareEncodeSupported' in scope

`VideoCompressionView.swift:32` 的選單條件呼叫不存在的符號；同次建置另回報 `VideoCompressionModel.swift:80` 的 weak self 擷取不一致警告。

### 根因 - VideoToolbox 沒有編碼版的硬體能力查詢函式

`import VideoToolbox` 早已存在，並非漏匯入。Apple 只提供 `VTIsHardwareDecodeSupported`（解碼）；編碼能力須以 `VTCopyVideoEncoderList` 搭配 `kVTVideoEncoderList_IsHardwareAccelerated`（iOS 13+）查詢。

### 修改 - 改查系統登錄的硬體編碼器清單，並保留寫入階段的最終驗證

新增 `VideoEncoderCapabilities`，程序內只列舉一次並快取支援硬體加速的編碼格式；清單不可讀或缺少硬體欄位時不預先隱藏選項，實際轉碼仍由 `RecordingTranscoder` 的 `writer.canApply` 把關。進度回呼移除多餘的 `[weak self]`，與外層一致強擷取單例。本機無法建置 iOS 目標，待 CI 確認。

## 2026.10.26 01:46 新增手動單檔影片壓縮頁

- 從碼率分析與錄影詳細資訊進入，提供碼率、尺寸／FPS 上限與音訊選項，支援進度及取消。
- 共用錄後轉碼服務新增另存模式，原片保留；結果存入 Documents/CompressedVideos，可分享或分析。
- 單一任務跨視窗共用，背景取消，偵測擷取時等待；完整限制見 VIDEO_COMPRESSION.md。
- 新增原檔不變整合測試；Apple SDK 編譯與實機驗收待 CI。

## 2026.10.25 23:12 接入 ReplayKit 旋轉加工在途負載

- 沿用 Socket 共用明細回報 Metal 在途比例、準備／完成耗時、旋轉角度、尺寸調整與時間層實際編入狀態。
- 重疊命令計算時間聯集，逾時仍等實際完成；CPU 後備明示負載未提供。
- 新增跨取樣重疊命令測試與中文說明；Apple CI／實機驗收待完成。

## 2026.10.25 13:25 新增加工 worker 區間忙碌比例

- 每五秒依實際間隔計算加工忙碌比例，包含跨取樣邊界的在途工作，首次建立基準不顯示假零。
- 設備資訊 ScreenCaptureKit 串流明細與日誌共用同筆結果，明示不是 CPU／GPU 使用率。
- 新增跨區間、結束後不重算、重複取樣與閒置回歸測試；Apple CI 驗收待完成。

## 2026.10.25 13:20 改善畫面加工合成與資源預算

- 改為 Core Image 一次合成，取消逐幀 CPU 疊加；時間層失敗降級為無疊加影片。
- 輸出依來源 RGB 色彩空間渲染，缺漏採明示 sRGB 後備，不誤貼來源 YUV／HDR 附件。
- 緩衝池按 48 MiB 估算預算推算容量，補設定範圍檢查、池耗盡與降級統計；診斷改存純量。
- 新增容量／降級測試並延伸色彩附件驗證；Apple CI、GPU 像素及實機效能驗收待完成。

## 2026.10.25 13:10 接入同幀時間診斷並補強畫面加工觀測

- 兩份套件鎖定更新至底層 992412e9，接入 VT 同幀時間與 RTMP 首筆／最新入列觀測，兩種來源沿用共用設備明細。
- ScreenCaptureKit 畫面加工每五秒及停止時回報結果、前後 PTS、尺寸、設定及各階段呼叫耗時；設備頁可查看摘要。
- 疊加設定改為每秒讀取，失敗明確回報；新增統計契約測試與中文說明。
- 本機 Swift 語法與核心統計驗證；Apple SDK 編譯、CI 及實機驗收待完成。

## 2026.10.25 00:41 補充影音來源起始與 PCM 時間跨度診斷

- CaptureCallbacks 記錄每軌首筆有限 PTS 與首次回呼 host time；共用 Mixer probe 記錄首筆影音時間。
- ScreenCaptureKit 來源 App／Mic 與混音輸出記錄 sample frames 累計、內容秒數、PTS 跨度與差值；格式變更另開世代，不修正原時間。
- 加入連續樣本、間隔、格式變更與無效時間回歸測試；Apple CI 及實機驗收待完成。
- 本批尚未串接編碼／RTMP 首包與重連世代，也尚未涵蓋 ReplayKit 分軌內容時長，不能視為完整端到端追蹤。

## 2026.10.25 00:16 補強 ScreenCaptureKit 回呼入口診斷

- 新增 CaptureCallbacks：各軌全部回呼、略過原因、影格狀態、最後回呼距今與最大回呼間隔。
- 記錄來源 PTS、倒退／無效計數及帶正負號的 host clock 與 PTS 差；標示 clockComparison=unverified，不直接當作延遲。
- 沿用五秒摘要並於收尾排空後保留最終快照；固定種類純量統計，不保留 buffer 或逐幀寫日誌。
- 新增計數、無效時間與倒退測試；Swift 語法通過，Apple CI／實機回呼驗收待完成。

## 2026.10.24 08:45 接入底層影音時間補償策略修正

- 兩份套件鎖定同步更新至 `6ac475ad`，底層測試通過；包含 `ebd0a827` 的跨軌自動補償移除。
- ReplayKit／ScreenCaptureKit 不再依最近影音輸出位置差推算影片補償，也不將落後音訊重標到影片位置；音訊封包節奏修正仍保留。
- 現有日誌入口可接收 publish timeline schema=2，包含 alignment=observeOnly、origins=perTrackFirstSample 與 sourceStartOffset；不需新增 API 呼叫。
- 套件 JSON、一致性及差異檢查通過；主 App CI、起播／停頓／重連後的內容同步待實機驗收。共同時間原點與跨階段影格追蹤尚未完成。

## 2026.10.22 22:34 接入 ScreenCaptureKit 音量監測與閒置基準

- ScreenCaptureKit 來源 App／Mic 在 Mixer 前限頻量測 RMS，混音後另列輸出 RMS；不以左右聲道代替來源分軌。
- 音量頁區分未收到、過期、停止與有效靜音；本機 session 拒收過期回呼，ReplayKit 沿用共用模型入口。移除接收音量後再次發送同名通知的回授。
- 頁面可見時每軌最高 5 Hz，其他時間 1 Hz；只複製當次限頻 PCM，不保留 buffer。
- 記憶體快照加入程序識別、60 秒未觀察到開播的基準、停止後實際經過秒數與 30／60／120 秒里程碑；不增加背景執行時間。PiP 分開顯示持有與設定容量估算。
- Swift 語法與差異檢查通過；新增測試及 Apple SDK 型別檢查待 CI，音量與停止後快照待實機驗收。

## 2026.10.21 18:48 更新底層影片停頓時間戳修正

- 兩份 Package.resolved 同步鎖定 `03c77703`，底層 CI 已通過。
- 接入 `8ba8a524` 的影片時間戳修正：保留影片停頓造成的真實向前間隔，避免超過 2 秒的間隔遭縮短而累積影音偏移；ReplayKit 與 ScreenCaptureKit 共用此 RTMP 路徑。
- 主 App 不需新增 API 呼叫；本次套件更新也包含底層 CI 流程修正。
- 套件鎖定一致性與差異檢查通過；主 App 建置及長時間推流、停頓恢復後的影音同步仍待 CI／實機驗收。

## 2026.10.21 00:11 補充閒置與背景資源快照

- 沿用 30 秒記憶體採樣，新增 IdleResources：App 狀態、擷取階段、曾啟動擷取、driver／lease 持有、PiP 繪製與影像池、TTS 朗讀及排隊數。
- 啟動、背景清理後、前景返回、記憶體警告與擷取完成額外取樣；不為採樣延長背景執行，也不初始化未使用的 PiP／TTS。
- ReplayKit 狀態僅為主 App 最後所知狀態，不代表擴展程序存活；影像池容量為估算，不作精確記憶體歸因。
- Swift 語法檢查通過，Apple 型別檢查及實機量測待驗收。

## 2026.10.20 19:11 接入心跳改進並修正診斷顯示

- 兩份套件鎖定接入 `99348ac4`；已確認底層測試通過。主 App 重連狀態修正與診斷隨本次提交接入。
- 影音管線卡片格式與說明文字完整換行，避免 iPad 雙欄截斷色彩欄位。
- 依實機截圖更新 ScreenCaptureKit 管線、編碼格式及傳輸統計的 TODO 驗收狀態。
- Swift 語法與差異檢查通過；主 App CI、卡片版面及重連實測仍待確認。

## 2026.10.20 16:46 更新底層心跳策略接入說明

- 底層工作目錄已改為接收進展清除連續失敗，曾回 pong 的對端連續三次無回應才重連；8 組心跳案例通過。
- 更新 log-58 文件；底層仍需發布後更新套件鎖定，逐 ping 傳送完成追蹤與影片時間戳修正尚待處理。

## 2026.10.20 16:11 補強 log-58 重連狀態與斷流診斷

- ScreenCaptureKit 重連中不再保留已發布狀態，恢復後等待新輸出摘要；忽略停止及舊工作回呼。
- 新增 log-58 調查說明，區分心跳斷線、S0S1 逾時與獨立的影片時間戳縮短問題。
- 底層工作目錄補心跳傳輸快照及時間戳診斷測試；尚未更新 App 套件鎖定，需底層發布後接入。

## 2026.10.20 13:38 主 App 編碼診斷接入驗收準備

- 使用者確認底層前置工作完成，核對兩份套件鎖定與共用快照入口一致。
- 補上兩種來源的非空 H.264／AAC 格式 JSON 往返與發布世代重設測試，驗證未知色彩不補值、重連不沿用舊格式。
- 更新主待辦與接入文件；主 App 完整 Xcode CI 與實機畫面仍待驗收。

## 2026.10.19 22:13 接入實際編碼格式快照

- 底層新增 RTMPStream.encodingDiagnostics()，主 App／ReplayKit 共用快照讀取影片與音訊的實際壓縮格式。
- 設備頁分開顯示格式變更與最近輸出時間、發布世代、壓縮樣本／packet／payload 累計；缺少色彩附件維持未知。
- 兩份套件鎖定更新至 7ce4304b；底層為本機提交，需先推送才可供遠端 App CI 解析。
- 補上中文 API 文件與序列化測試；Swift 語法檢查通過，Apple 平台型別檢查與測試待 CI。

## 2026.10.19 22:01 共用管線輸出圖表、介面流量與 MetricKit 單位

- ReplayKit／ScreenCaptureKit 共用 Mixer 影片、PCM 輸出速率圖表；歷史每來源最多 60 筆，保留舊版缺值相容。
- ScreenCaptureKit 診斷探針移至擷取管線生命週期，本地可控錄製也能回報；系統直接錄製不經 Mixer。
- 設備頁增加介面上下行速率，清楚區分整個介面與 App／RTMP 流量，回前景重新取樣。
- MetricKit 列表與詳細頁自動換算容量，詳細頁可切回原始單位，JSON 不變。
- BGRA 明確標示 RGB 與 YUV 範圍分類的差異；實際編碼格式尚缺底層公開快照，畫面說明限制。
- 補充測試與 `Docs/development/DEVICE_DIAGNOSTICS.md`；完整 Apple 平台建置與實機數據待 CI／裝置驗收。

## 2026.10.18 09:03 音量分組與平板卡片空洞補正

- 音量頁拆 App／麥克風卡片，區分設定與最近回報，進階收納增益及原始值；保留原有換算、通知與套用時機。
- 設備頁改為獨立雙欄共用捲動，避免網格行高留下空洞。
- PiP 加工預覽限寬、與設定並排並提供放大；新文案含繁中、英文、日文。
- Windows 語法及靜態檢查，實際布局與即時音量控制待 iPad 驗收。

## 2026.10.18 07:33 接入底層 RTMP 時間軸診斷

- 兩份套件鎖定檔已更新至 d7ece588；ScreenCaptureKit 白名單新增 publish timeline、音訊 resync 與影音補償事件。
- ReplayKit 沿用 RTMP 日誌開關與事件轉送，補充啟用條件、指標限制及實機驗收文件。
- 本次接入日誌，不把文字日誌解析成設備頁指標；完整 App／擴展建置仍待 CI。

## 2026.10.18 07:32 平板導航與設定卡片布局修正

**類型**：介面修復 · **檔案**：`Navigation/`、`TTSSettingsView.swift`、`OverlaySettingsView.swift`、`OtherView.swift`、`StreamDiagnosticsView.swift`

- 音訊分頁統一導覽容器，限制子頁切換列寬度，分頁名稱縮短為音訊。
- TTS／設備資訊依視窗與字體切換單雙欄；設備卡片拆分，管線圖表提供展開入口。
- 畫面加工預覽限制尺寸，寬視窗與設定並排，提供放大預覽；補繁中、英文、日文入口文字。
- 保留設定及採樣所有權；語法檢查通過，iPad 實際布局與導航待實機驗收。

## 2026.10.17 21:23 第二批五分頁整併

**類型**：介面整理 · **檔案**：`ContentView.swift`、`Navigation/MainTabViews.swift`

- 頂層整併為主頁、設備資訊、日誌、音訊與設定；聊天移到主頁子入口，碼率分析移到設備資訊子入口。
- 音訊頁提供音量／TTS 切換；集中音量訂閱條件，TTS、其他分頁及非前景時停用即時音量資料。
- 沿用服務與偏好儲存，補充導航文件與實機驗收項目；Windows 僅能檢查 Swift 語法，iOS 操作待 CI／實機驗收。

## 2026.10.17 03:18 全域設定移出日誌並建立分類分頁

**類型**: 介面整理 · **檔案**: `ContentView.swift`、`FileLogView.swift`、`Setting.swift`、`Settings/`、`Localizable.xcstrings`

- 主頁旁新增獨立設定分頁；主頁使用房子圖示，設定使用齒輪。
- 全域設定整理為一般、連線、音訊、畫面與疊加、PiP、日誌、進階及關於入口。
- 日誌頁快捷入口只開啟日誌設定，與設定中心共用同一頁；編碼、聊天通知、維護操作及舊版 PiP 外觀移往各自分類。
- 保留原有偏好鍵與通知回呼；日誌端點只有變更時才送出更新通知。新導航補繁中、英文、日文。
- 本批保留其他分頁與既有生命週期判斷；Swift 語法、偏好／通知搬移核對通過，iOS 導覽與即時操作待實機驗證。

## 2026.10.17 03:11 CI 同分支新執行取消舊執行

**類型**: 工作流程 · **檔案**: `.github/workflows/`、`Docs/development/CI_CONCURRENCY.md`

- 測試、索引、tag 與 DocC 加入按 ref 分組的取消策略；發布依上游來源分支分組。
- 共用測試使用獨立前綴；失敗或取消的上游事件隔離，避免誤取消正常發布。
- Pages 部署保留共用序列化群組；文件說明已發布副作用不回滾、舊版重跑及實跑驗收方式。

## 2026.10.15 22:58 修正整數解碼指標生命週期與 RTMP 發布診斷

**類型**: 修復 · **檔案**: `Package.resolved`

### 修改 - HaishinKit 與 MoQTHaishinKit 的整數複製改在 Data.withUnsafeBytes 有效閉包內完成，避免短 Data 解碼讀取失效指標

- Set Chunk Size 原始四位元組獨立記錄；零值、超出支援上限及錯誤長度明確關閉，不再靜默截斷數值。
- 診斷延伸至 createStream／發布啟動，維持每連線 192 筆上限；命令逾時包含解析進度與 socket 傳送統計，不含金鑰。
- 新增短 Data、切片與分段控制訊息回歸測試。Restream 恢復與否仍待主 App 更新套件後實測。

---

## 2026.10.15 21:23 加入 MetricKit 報告可視解讀

**類型**: 功能 · **檔案**: `MetricReportAnalysis.swift`、`MetricReportsView.swift`、`MetricReportAnalysisTests.swift`

- 詳細頁預設呈現分類指標、欄位說明、缺漏提示、版本與裝置資訊，保留原始 JSON 查看及分享。
- 裝置磁碟容量提供使用比例圖，區分 App 檔案大小與整台裝置容量；未知單位及無效比例不繪圖。
- 異常事件顯示分類筆數，巢狀資料與堆疊保留原文；不將缺少記憶體資料誤判為零或正常。
- 補充解讀 API 文件與回歸測試；完整 iOS 畫面仍需實機驗收。

## 2026.10.15 09:56 修正設備資訊頁無法開啟 MetricKit 報告

**類型**: 修復 · **檔案**: `ContentView.swift`、`MetricReportsView.swift`、`MetricReports.swift`

- 設備頁原本直接置於 TabView，NavigationLink 缺少導覽容器；新增該分頁專用 NavigationStack，支援報告列表、詳細頁與返回。
- 報告頁與儲存屬性註釋明確說明使用主 App 的 Documents/MetricReports，不依賴 App Group，側載沿用相同路徑。
- Swift 語法與差異檢查通過；列表點擊、返回及 JSON 分享需在 iOS 實機驗證。

## 2026.10.15 07:49 修正設備診斷採樣生命週期與停止狀態

**類型**: 修復 · **檔案**: `OtherView.swift`、`StreamDiagnosticsView.swift`、`CaptureStreamTelemetry.swift`、`ScreenCaptureSource.swift`、`MemorySampler.swift`

- ScreenCaptureKit 本機管線與 RTMP 診斷共用生命週期提示；停止後保留最後快照，不再累計過期秒數。推流失敗但錄影仍運作時分開顯示。
- 設備頁只在可見且 App 位於前景時採樣，離頁／進背景取消工作；診斷區塊共用時間，新增 `[DeviceDiagnostics]` 採樣啟停日誌。
- CPU 查詢移出畫面建構，採樣器狀態固定保存；host port 配對釋放，速率依實際間隔計算，恢復時重設基準。
- 擷取收尾等待診斷工作結束，跨 actor 查詢返回後檢查取消，避免晚到快照。
- 修正記憶體分類加總說明，新增停止／過期／推流失敗但擷取繼續的回歸測試。實機約 300 MB 的保留來源仍待驗證，本次不宣稱已修復全部記憶體增長。

## 2026.10.15 07:04 改善音訊時間驗證與 CI 失敗分類

**類型**: 測試／工具 · **檔案**: `SegmentedRecordingTests.swift`、`Scripts/ci_test_summary.py`、`.github/workflows/unit-tests.yml`

- 音訊時間測試改驗證解碼後測試訊號起點，保留 0.1 秒門檻與缺音失敗條件；不再假定首個 AAC 封包就是聲音起點，仍須 CI 驗證。
- 問題紀錄、測試函式終態與整體 run 分開解析，避免把三個斷言問題及 run 結果誤算成多個失敗測試。
- 摘要保留參數、斷言與實際數值；失敗獨立分塊，通過清單收合，runner 診斷收集逾時獨立顯示。
- 新增解析器回歸測試並接入單元測試 workflow。

## 2026.10.15 07:01 補充分段音訊時間戳測試診斷

**類型**: 測試 · **檔案**: `liveAPPTests/SegmentedRecordingTests.swift`

- 保留原本 0.1 秒時間差斷言，補實際／預期 PTS、片段序號、影音軌時間範圍及封包時長。
- 本次失敗位於匯出音訊時間驗證，摘要沒有實際數值；根因仍待完整測試輸出確認，不將診斷補強視為音訊位移已修復。

## 2026.10.15 06:34 修正非交錯 PCM 的跨段音訊切分

**類型**: 修復 · **檔案**: `SegmentedRecordingRouter.swift`、`RecordingPCMSlicer.swift`、`SegmentedRecordingTests.swift`

- 通用 CMSampleBufferCopySampleBufferForRange 不支援非交錯音訊，跨界測試回傳 -12735；改用 PCM 專用複製 API，再建立獨立樣本。
- 依音訊幀偏移與取樣率計算新 PTS，保留原格式及聲道排列；錯誤回報包含失敗階段與幀範圍。
- 保留跨界整合測試，新增交錯／非交錯 PCM 的逐聲道內容、幀數與時間戳連續性驗證；Apple SDK CI 待重跑。

## 2026.10.15 06:04 修正錄影合併時間範圍的參數標籤

**類型**: 修復 · **檔案**: `liveAPP/Capture/RecordingGroupMerger.swift`

- 影音兩處 CMTimeRangeGetIntersection 呼叫補上 Swift 必要的 otherRange: 標籤，修正 Apple SDK 編譯錯誤。
- 不變更時間範圍計算；完整編譯仍需 CI 確認。

## 2026.10.15 02:02 改善分段音訊邊界、錄影畫布與群組合併

**類型**: 修復／新增 · **功能 ID**: `recording.segmented`

- 對照 log-54 與 120 秒樣本影片，確認音訊封包約 115.3 秒結束；既有日誌不足以唯一確定原因，不宣稱已完成實機修復驗收。
- 新舊片段短暫並存，依 PTS 接收晚到音訊並切分跨界 PCM；封裝收尾移出一般收樣本流程，增加逐軌丟棄與影音尾端診斷。
- 錄影畫布提供明確寬高、留邊／裁切，疊加層共用畫布座標；停止擷取時排空已接受樣本。
- 本地錄影以場次群組顯示，提供手動及可選停止後合併，保留原片段並驗證產物。
- 補群組與晚到音訊回歸測試；Apple SDK CI、實機接縫與負載驗收仍待完成。

## 2026.10.15 01:13 回報分段錄影檔案大小讀取錯誤

**類型**: 修復 · **檔案**: `liveAPP/Capture/SegmentedRecordingWriter.swift`

- 以 do／catch 取代吞掉錯誤的 try?，透過 sendlog 記錄片段、階段及 NSError 詳情。
- 失敗時保留最近已知大小並顯示未確認提示；相同連續錯誤去重，恢復讀取時記錄恢復事件。
- 每段重設大小與錯誤狀態；缺少有效 size 屬性也視為讀取失敗。

## 2026.10.15 01:10 修正錄製排空測試與片段容量讀取

**類型**: 修復 · **檔案**: `RecordingDrainTests.swift`、`SegmentedRecordingTests.swift`、`SegmentedRecordingWriter.swift`

- 排空測試明確指定保留待處理樣本；預設關閉仍保持丟棄語意。
- 片段容量改查檔案系統屬性，避免重用 URL 資源屬性快取。
- 分段測試分開驗證完成狀態、實體檔案大小及紀錄容量一致性，失敗附帶片段與佇列診斷。
- 分段整合測試仍需 Apple SDK CI 重跑確認，現有摘要不足以完全確認第二項失敗根因。

## 2026.10.15 00:40 修正分段錄製收尾的 URL 變數遮蔽

**類型**: 修復 · **檔案**: `liveAPP/Capture/SegmentedRecordingWriter.swift`

- 更正前次將 `let` 改成 `var` 的修法：解包後的區域變數仍是非 Optional `URL`，不能賦值 `nil`。
- 驗證檔案使用 `segmentURL`，收尾明確清除 `self.url` 等實例屬性，避免同名區域變數遮蔽。
- Swift 語法與差異檢查通過；完整 Apple SDK 建置仍待 CI 確認。

## 2026.10.15 00:04 修正語法問題 更正不可變參數修正為可變

**類型**: 修復 · **檔案**: `liveAPP/Capture/SegmentedRecordingWriter.swift`

### 問題 - liveAPP/Capture/SegmentedRecordingWriter.swift:236 cannot assign to value: 'url' is a 'let' constant

`liveAPP/Capture/SegmentedRecordingWriter.swift:236` 'nil' cannot be assigned to type 'URL'

- error: cannot assign to value: 'url' is a 'let' constant
- error: 'nil' cannot be assigned to type 'URL'

```swift
guard writer.status == .completed, videoCount > 0 else { 
   throw writer.error ?? error("片段未完整收尾，原檔保留供恢復。") 
}

guard var url else { throw error("缺少片段路徑。") }

let asset = AVURLAsset(url: url)

let duration = try await asset.load(.duration)
        
guard try await asset.load(.isPlayable), duration.seconds.isFinite, duration.seconds > 0,
      !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
    throw error("片段可播放性驗證失敗，檔案保留。")
}
        
await report(phase: .ready, completedDuration: duration.seconds)
        
sendlog(message: "[SegmentedRecording] group=\(group) segment=\(number) completed dropped=\(dropped)")
// 完成後清理
self.writer = nil; video = nil; audio = nil; id = nil; url = nil
```

### 根因 - 在後續清理操作 試圖把 url清空

但url被設為常數造成錯誤

### 修改 - 更正為 let 為 var 可變參數

```swift
guard var url else { throw error("缺少片段路徑。") }
```

---

## 2026.10.14 13:46 新增可控分段錄製、即時混音與系統品質匯出

**類型**: 新增 · **功能 ID**: `recording.segmented`、`recording.post-compression`

- 可選直接編碼 MP4，平均碼率可指定或交由編碼器決定；每 1／2／5／10 分鐘獨立保存一段，預設 2 分鐘。
- Mixer 與 RTMP 生命週期分開，推流與可控錄製即時共用應用／麥克風音量；系統錄製保留。
- 片段內寫入 movie fragments；中斷檔案需驗證可播放才恢復，已完成片段保持獨立。
- 錄後處理新增系統高品質與多次編碼請求；不把系統預設描述為 CRF 固定品質，不保證多次編碼一定採用。
- 補佇列排空與分段整合測試。實機音畫同步、切段與意外中止恢復仍待驗收。
- 補齊錄製與 MetricKit 的 Swift 文件註釋，更正片段編號、丟棄計數範圍、固定軌道與未完成檔案恢復限制。

**相關文件**: [錄影設定與限制](development/RECORDING_COMPRESSION.md)

## 2026.10.14 13:26 接入 MetricKit 並分開顯示錄影壓縮容量

**類型**: 新增／修正 · **功能 ID**: `diagnostics.metrickit`、`recording.post-compression`

- 主 App 集中訂閱 MetricKit，限量保存本機 JSON，設備資訊提供查看與分享；附接收時 BuildInfo，不自動上傳。
- 錄影分開保存壓縮前／後容量，處理中標明未完成，成功顯示節省 MB 與百分比；舊紀錄不推算缺少值。
- 補充單檔持續寫入、錄後壓縮碼率與音量設定的限制，新增容量相容性測試與後續管線 TODO。
- Apple SDK 建置、MetricKit 交付與錄影 UI 實機驗收待完成。

**相關文件**: [MetricKit](development/METRICKIT.md)、[錄後壓縮](development/RECORDING_COMPRESSION.md)

## 2026.10.14 04:06 修正錄後壓縮測試巨集編譯與 DocC 重複收錄

**類型**: 修正 · **檔案**: `RecordingCompressionTests.swift`、`liveAPP.xcodeproj/project.pbxproj`

- 將修改狀態的 FPS 判斷先存為區域結果，再交給 `#expect`，避免巨集展開使用不可變接收者而無法編譯；保留原有斷言。
- DocC 保留既有手動 Sources 設定，從同步資料夾自動收錄中排除，消除重複建置項目。
- 完整 iOS 建置與測試結果仍需 CI 確認。

## 2026.10.14 02:46 ScreenCaptureKit 本地錄影加入可選錄後壓縮

**類型**: 新增 · **功能 ID**: `recording.post-compression`

- 新增預設關閉的 SDR 錄後壓縮，可選 HEVC／H.264、1–40 Mbps、最長邊與 FPS 上限（預設 60）；開錄時固定設定。
- Reader／Writer 與方向修正共用一次轉碼，AAC 保留；產物驗證且較小才替換，失敗保留原始錄影。
- 更正「HEVC 必然較小」提示，補設定與耗時錯誤日誌、純邏輯測試、功能索引及使用文件。
- 限制：不降低初次錄製 I/O；Apple SDK 建置及實機驗收仍待完成。

**相關文件**: [錄後壓縮](development/RECORDING_COMPRESSION.md)

## 2026.10.12 10:24 fork pin 前進至 c3a5e3d8（修正 RTMP 關閉死鎖）

**類型**: 修正 · **檔案**: `Package.resolved` 兩份

### 問題

ScreenCaptureKit 推流在「App 進背景再回來（無 PiP 保活）」後，手動停止會卡在「正在停止」永不復原——狀態機停在 `.stopping`，`update(.idle)` 永遠不會被呼叫，UI 無法回到可再次啟動的狀態。

### 根因

底層 `RTMPConnection.close()` 的 `await socket?.drain()` 會一直等 `drainWaiters.finish()`，而唯一的釋放者是排在它**之後**的 `socket?.close()`。連線若已死透（App 被暫停後 socket 被系統拆掉），最後一次送出完成不會回報、`didSendChunk` 不觸發 → `drain()` 與 `close()` 互等卡死；連線關不掉、`finish()` 便走不到結尾，狀態永遠停在 `.stopping`。（實機 log 顯示連線早先已因 `recvLoopEnded` 嘗試關閉，卻沒走到 `state = disconnected`。）

### 修改

- fork（`c3a5e3d8`）：`RTMPSocket.drain()` 改為**有界**（預設 2 秒，逾時自行釋放等待者並記 `Socket drain timed out`）；`RTMPConnection.close()`／`RTMPStream.close()`／`deleteStream()`／`finishOutputConsumer()` 補步驟日誌，下次若仍卡住可直接看出卡在哪個 await。
- 主 App：`Package.resolved` 兩份 pin 前進至 `c3a5e3d8`（`close()` 時序不再死鎖）。

---

## 2026.10.11 01:10 開發索引：近期改動可展開檢視 diff（含語法上色）

**類型**: 功能 · **檔案**: `Scripts/changelog/devindex.py`、`assets/dev.{js,css,html}`、`assets/theme.css`、`assets/file.css`、`Scripts/dev_index.py`、`Scripts/test_dev_index.py`、`Docs/development/README.md`

### 內容

- 開發索引「近期改動／版本」分頁：提交與未提交變更改為**可展開**，展開時即時抓取該提交（或工作區）的 unified diff，並以語法上色呈現（與檔案檢視共用色票）。
- 後端 `devindex.py`：`git log` 改用 `%x1e`／`%x1f` 控制字元分隔的**結構化提交**（`_parse_commits`）；新增 `diff()`（`git show`／`git diff HEAD`；`_safe_pathspec` 防路徑穿越、`_REV_RE` 防提交注入、`MAX_DIFF` 截斷）與 `GET /development/diff` 路由；`git()` timeout 15→30 秒。
- 前端 `dev.js`：新增 `commitCard`／`renderDiff`／`loadDiff`（含結果快取）與事件委派（提交標題、檔名、工作區差異鈕）。
- 樣式：`dev.css` 新增提交卡片與 diff 樣式；`.tok-*` 語法色票自 `file.css` 移到 `theme.css`（檔案檢視與差異檢視共用）；`dev.html` 載入 `highlight.js`。
- 相容入口 `Scripts/dev_index.py` 匯出 `diff`；`test_dev_index.py` 新增提交結構與 `/development/diff` 測試（含 400 防護）。
- 已本機啟動工具、以瀏覽器驗證：展開 Swift 提交的 diff 產生 419 個語法上色 token（`tok-k/t/f/s/c/n/a`）。

---

## 2026.10.10 23:25 fork pin 前進至 07a4df41（不採回退策略）

**類型**: 優化 · **檔案**: `Package.resolved` 兩份

- 決定：不為低層 CI 暫時失敗而回退 pin。每個 fork revision 都會被建置／保存，新版本失敗時使用者仍可取用舊版，因此直接前進到修正後的 fork HEAD **`07a4df41`**（含 `requestTimeout` 8s、握手逾時測試事件驅動、推流診斷 close 原因／SetChunkSize raw／輸出 PTS 倒退、`close()` 協定修正）。
- 此筆取代前一筆 23:05 的回退。

---

## 2026.10.10 23:05 回退 fork pin 至 2e2919af（低層 CI 未過，先不動主 App）

**類型**: 修正 · **檔案**: `Package.resolved` 兩份

### 內容

- fork `7b2e222f` 把 `RTMPConnection.close()` 改成 `close(reason:)`，破壞了 `HaishinKit.NetworkConnection` 協定一致性（該協定要求 `func close() async throws`）→ macOS/iOS 編譯失敗。
- 已在 fork 修正（`07a4df41`）：保留 `close()` 作為協定 witness（內部轉呼叫 `close(reason: "external")`），另新增 `public close(reason:)`。
- 依「先等底層 CI 綠燈，再更新主 App pin」原則，主 App 的 `Package.resolved` **先回退到最後已知可用的 `2e2919af`**；待 fork `07a4df41` 的 macOS/iOS CI 通過後再更新。

---

## 2026.10.10 22:20 補強推流診斷（close 原因、chunk 原始位元組、輸出 PTS 倒退）

**類型**: 優化 · **檔案**: fork `RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift`、`RTMPStream.swift`；本 repo `Package.resolved` 兩份 pin → `7b2e222f`

### 動機

- 直播偶發 `ECONNRESET`（對端重置）時無法分辨是誰要求關閉、是否本機送出異常。

### 內容

- `RTMPConnection.close(reason:)`：`reason` 寫進 `Close requested` 日誌。內部來源標註：`serverClose`（伺服器送 close 命令）、`stageTimeout`、`recvLoopEnded`／`recvLoopError`、`protocolError.s0|connectMessage|chunkType`；其餘為 `external`（呼叫端）。
- SetChunkSize 診斷新增 `raw=<hex>`（確認伺服器 4 bytes 真值；先前解碼已確認符合大端規範）。
- `publish throughput` 新增 `outputPTSAdvanced` 與 `ptsRegress{v=…,a=…}`（video/audio 輸出時間戳倒退累計），用來判斷「我們發的包時間戳是否亂序」。

---

## 2026.10.10 21:05 推流輸出畫布政策（16:9 / 跟隨來源）與疊加層改以畫布為座標

**類型**: 功能 · **檔案**: `liveAPP/Capture/StreamFramePolicy.swift`（新）、`ScreenStreamVideoRotator.swift`、`ScreenCaptureSource.swift`、`CaptureCoordinator.swift`

### 內容

- 新增 `StreamFramePolicy`：`.standard`（16:9 含黑邊，**預設**）、`.standardFill`（16:9 裁切填滿）、`.native`（跟隨來源比例），存於 `streamFramePolicy`。
- GPU 影像階段（`ScreenStreamVideoRotator`）改為真正的「畫布合成器」：把（旋轉後）來源依 fit/fill 縮放、置中到輸出畫布、補黑底並裁到畫布；**疊加層一律以輸出畫布為座標系**（錨點＝畫布四角）。先前疊加畫在來源座標、黑邊由 encoder 事後補，兩個座標系不一致才會「疊加在內容上、進不了黑邊」。
- 注意：`CIContext.render(_:to:)` 會把 image 的 extent 映射到整個緩衝，故必須「裁到畫布 + 疊黑底」讓 extent 恰等於畫布尺寸，否則被拉伸。
- `ScreenCaptureSource.preparePublishing` 依政策設 `videoSettings.videoSize`（固定畫布為 1920×1080、native 沿用擷取尺寸）並傳入 pump/compositor。
- 「擷取與開始」頁（SC 模式、推流）新增「輸出畫布」選單。

---

## 2026.10.10 08:40 更新 HaishinKit fork（握手逾時測試改正）並更新 pin

**類型**: 優化 · **檔案**: `Package.resolved`、`liveAPP.xcodeproj/.../Package.resolved`、fork `RTMPHaishinKit/Tests/RTMP/RTMPConnectionHandshakeTimeoutTests.swift`

### 問題

- fork CI 的 `等不到 S0S1：握手逾時並標明 waiting S0S1` 偶發失敗（`POSIXErrorCode(rawValue: 60)`）：測試 helper 以「固定 5 秒 deadline + 輪詢」判定本機 `NWListener` 是否 ready，CI 排程一擠壓即誤判；逾時又只丟合成的 `ETIMEDOUT`，看不到真正原因。

### 修改

- fork（`HaishinKitFixSwfit`，commit `2e2919af`）：測試 helper 改為**事件驅動**——listener `.ready` 立即回傳、`.failed` 回報真實 `NWError`、`.waiting` 記下真因；backstop 僅防無限等待且優先回報該真因。
- 本 repo `Package.resolved` 兩份 pin 更新至 `2e2919af`。

---

## 2026.10.10 08:05 週期記憶體明細取樣（追查 footprint 爬升）

**類型**: 優化 · **檔案**: `liveAPP/MemorySampler.swift`（新）、`liveAPP/liveAPPApp.swift`

### 問題

- log-51（ReplayKit 廣播、PiP 開）顯示主 App footprint 由 192MB 單調爬升到 314MB（約 +6~7MB/分），顯為累積；但日誌只有 `[LiveActivity] mem=` 與 `[CaptureResources]` 的總量與少數欄位，無法定性「誰在漲」。

### 修改

- 新增 `MemorySampler`：每 30 秒輸出一行 `[Memory] footprint/internal/compressed/external/reusable/purgeable/resident/avail | urlCacheMem/urlCacheDisk`，於 `liveAPPApp.init()` 啟動；純觀測、不改狀態。

### PiP 快取檢查結論

- `PiPImageCache`（圖片）：NSCache `countLimit=20`、`totalCostLimit=20MB`，且 in-flight／pending／queue 於完成時清除 → 正常。
- `PIPMetalRenderer.textTextureCache`：字典以「文字全字串」為 key、**無上限且 `clearTextCache()` 從未被呼叫**；但整個 `PIPMetalRenderer` 目前**無人使用（dead code）**，故非本次洩漏來源（已記錄，待日後清理）。
- `LayerPool`／pixel buffer pool：pool 大小有界、buffer 重用 → 正常。

### 待驗證

- 需裝置重現後看 `[Memory]` 逐行：確認是 internal 還是 compressed 在漲，搭配 `urlCache` 等欄位定位實際累積來源。

---

## 2026.10.10 07:40 放寬 RTMP 命令逾時（修正 createStream requestTimedOut）

**類型**: 修復 · **檔案**: `Package.resolved`、`liveAPP.xcodeproj/.../Package.resolved`、fork `RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift`

### 問題

- 推流到 Restream 時偶發 `Command timeout cmd=createStream` → `publish: failed with requestTimedOut`；TCP／handshake／`connect` 皆成功，只有 `createStream` 逾時。
- 逾時值 `RTMPConnection.defaultRequestTimeout = 3000ms`；失敗時序與 App 進入 `.inactive`（`正在離開App`）吻合——App 被系統暫停收包，伺服器回覆來不及在 3 秒內處理。

### 修改

- fork（`HaishinKitFixSwfit`，commit `51774900`）：`defaultRequestTimeout` 由 `3000` 放寬到 `8000` 毫秒；正常回覆仍在毫秒級，8 秒用於吸收短暫的前後景轉換。
- 本 repo `Package.resolved` 兩份 pin 更新至 `51774900`。

---

## 2026.10.10 07:30 Socket listener 等待/拒絕連線診斷

**類型**: 優化 · **檔案**: `liveAPP/Socket.swift`

### 問題

- 排查「Socket 連不進來」時，`NWListener` 的 `.waiting`（尚未可接受連線）狀態與「收到連線卻被丟棄」都沒有落檔，log 只看得到 `starting/ready`，無法判斷當下 listener 是否真的可連。

### 修改

- `configureListener`：`.waiting` 狀態補 `logTo("SocketServer waiting …")`。
- `newConnectionHandler`：因 listener 已替換或 `wantsRunning=false` 而拒絕連線時補 `logTo`。

### 待驗證

- 需裝置重現後提供新 log：確認是否出現 `.waiting`，以及是否有「收到連線但拒絕」。

---

## 2026.10.08 02:14 改用系統標頭橋接 Socket 通知 API

- 移除無法解析的 DarwinNotify 匯入；新增 liveAPP_Bridging_Header.h，從系統 notify.h 匯入通知函數與常數。
- 僅設定主 App Debug／Release 的 SWIFT_OBJC_BRIDGING_HEADER；保留原本通知與恢復行為。
- 已核對設定範圍與標頭路徑；完整 Apple SDK 編譯及 DocC 建置仍須重跑 CI 驗證。

## 2026.10.07 21:11 修正 Socket 通知 API 模組匯入

- 曾嘗試在 Socket.swift 匯入 DarwinNotify；後續 Apple CI 確認該模組無法解析，此嘗試未修復編譯，已由下述 bridging header 修正取代。
- 保留既有恢復策略；Windows 語法檢查不涵蓋 Apple SDK 名稱解析，修正需由 Apple CI 重新驗證。

## 2026.10.07 20:55 模組檔名統一使用底線

- 將三個模組檔名的加號改為底線，同步更新原始碼註釋、模組文件與功能索引。
- 僅調整檔名及引用，程式行為不變。

## 2026.10.07 20:27 Socket 恢復入口與通知生命週期修正

- Darwin 回呼改為服務佇列上的弱參考 block；移除裸 observer 指標及 deinit 非同步 stop。
- 統一恢復判斷，保留 ready／setup／waiting；停止不被通知推翻，端口切換與占用另行處理。
- 重試合併並使用單調時間冷卻；停止使舊排程及等待 ready 失效，拒絕舊 listener 的晚到連線。
- 修正狀態註釋及 UI 顯示，新增恢復策略測試。Apple 通知／Network 整合驗收仍待完成。
- 文件：[Socket 模組與恢復設計](development/SOCKET_MODULES.md)。

## 2026.10.07 20:12 Socket 註釋與輔助模組整理

- 拆出 listener 日誌表示、JSONValue 模型與音量日誌格式，補充收送佇列及生命週期註釋。
- JSON null 與 UserDefaults 值轉換分離；非有限音量值明示無效，新增邊界測試。
- 維護入口：[Socket 模組說明](development/SOCKET_MODULES.md)。

## 2026.10.07 18:12 第二批編碼模組與診斷欄位契約

- 拆出編碼卡片與 VideoToolbox 能力查詢；移除固定 FPS 的 H.264 Level 推算，ReplayKit／ScreenCaptureKit 推流共用設定解析。
- 保留使用者新增註釋，修正健康指標單位；混音取樣率數值接入共用快照與設備資訊，延遲預留欄位不補零。
- 新增設定遷移與舊訊息相容測試，Apple CI／實機驗收待完成。
- 文件：[編碼選項與健康指標](development/ENCODING_CAPABILITIES.md)。

## 2026.10.07 13:42 修正主頁配置保存與初始化副作用

- RTMP 編輯改為草稿，明確保存並套用；取消或離開不覆寫原配置。
- 主頁不再於初始化回填示例端點；碼率改單一來源並限制有效範圍。
- 廣播擴展解析由 Coordinator 快取，失敗節流重試。
- 新增配置與碼率回歸測試，完整 iOS 驗收待 CI／實機。

## 2026.10.07 13:09 主頁第一批模組拆分與文件註釋

- ContentView 縮為頂層分頁入口，拆出 HomeView 狀態與卡片、RTMP 表單、廣播按鈕、碼率及設定型別。
- 保留既有型別名稱、狀態所有權與生命週期，補充重要型別、屬性與操作的中文 `///`。
- 搬移內容比對及語法檢查通過；CI／實機回歸待驗證。
- 維護入口：[主頁模組說明](development/HOME_MODULES.md)。

## 2026.10.07 05:02 DocC 模組根目錄轉址修正

**類型**: 修復 · **檔案**: `Scripts/docc_postprocess.py`

### 問題

- DocC 模組頁實際在 `<module>/documentation/<topic>/`，直接開 `<module>/`（例如 `/ReplyKit/liveAPP/`）會顯示「找不到頁面」；首頁連結因此導向錯誤位置。

### 修改

- `docc_postprocess.py` 新增 `write_module_redirects()`：偵測每個模組的 `documentation/<topic>`，把 `<module>/index.html` 改寫為轉址到內容頁；首頁只列有內容的模組。

### 驗證

- 本機以模擬站台驗證轉址與首頁連結正確；需 CI 部署後確認 `/ReplyKit/liveAPP/` 等可正常渲染。

---

## 2026.10.07 03:41 設備資訊接入雙來源串流格式與 RTMP 傳輸診斷

- ReplayKit 經 Socket、ScreenCaptureKit 直接更新共用快照，每五秒取樣並顯示過期狀態。
- 顯示 Mixer 實測格式、編碼設定、影片產出與入列事件、Socket 完成／失敗計數。
- 實際壓縮格式、chunk 與 ACK 未提供，保持未知；詳見 [接入說明](development/STREAM_DIAGNOSTICS.md)。
- 新增快照相容與舊資料隔離測試，iOS 建置及實機驗收待執行。

## 2026.10.07 03:29 加強擷取停滯與記憶體診斷及單視窗防呆

- 明確關閉多視窗，裝置頁避免重複取樣計時器。
- 區分 ReplayKit 圖表與 ScreenCaptureKit 本機摘要，顯示資料過期時間。
- 增加低頻記憶體及收尾 await 階段日誌；尚未宣稱修復記憶體增長。
- 調查與驗收：[log-49 診斷](development/LOG49_DIAGNOSTICS.md)。

<!--
新增紀錄請複製以下範本，貼到最上面（最新在上），並填寫內容：

## YYYY.MM.DD HH:MM 一句話標題
（時間可省略；由工具新增時會自動帶入當下時刻）

**類型**: 修復 · **檔案**: `liveAPP/Socket.swift`

### 問題 - 症狀摘要
（可選）其後換行寫詳述

### 根因 - 根因摘要
（可選）其後換行寫詳述

### 修改 - 手法摘要
- 其餘改動條列

**相關文件**: [xxx.md](xxx.md)（可選）
-->

## 2026.10.07 00:20 修正 HaishinKit fork 重複 DocC catalog 並更新 pin

**類型**: 修復 · **檔案**: `Package.resolved`（root 與 xcodeproj）

### 問題

- fork 的 `HaishinKit`／`RTMPHaishinKit` 各自有 `Docs.docc` 與 `Documentation.docc` 兩個 catalog，Xcode 27 報 `Each target may contain only a single documentation catalog`，使 `docbuild` 失敗（BUILD DOCUMENTATION FAILED）。

### 修改

- fork（`HaishinKitFixSwfit`，commit `f04e19e2`）：保留上游內容較完整的 `Docs.docc`，把新診斷的 Topics／`VideoPipelineDiagnostics.md` 併入，刪除 `Documentation.docc`（兩個 target）。
- 本 repo：`Package.resolved` 兩份 pin 更新至 `f04e19e2`。

### 驗證

- 需 CI 確認 `docbuild` 成功、站台含 `liveAPP` 等模組且頁面正常渲染。

---

## 2026.10.06 23:55 修正 DocC 子路徑空白頁並加入回饋連結

**類型**: 修復 · **檔案**: `.github/workflows/documentation.yml`, `Scripts/docc_postprocess.py`

### 問題

- 多模組各自 `transform-for-static-hosting` 到 `site/<Module>` 後，SPA 仍以**根目錄**參照資產（`baseUrl = "/"`、`src="/js/…"`），在 `/<repo>/<Module>/` 被託管時一律 404，頁面空白。

### 修改

- `--hosting-base-path` 改帶前導斜線（`/$BASE/$MODULE`）。
- 新增 `Scripts/docc_postprocess.py`：若 SPA 仍以根目錄參照，補上 `/<repo>/<module>/` 前綴；並產生根目錄 `index.html`（列出各模組，附 Discord／Twitch 回饋連結）。

---

## 2026.10.06 23:26 DocC 每模組輸出與根目錄首頁

**類型**: 修復 · **檔案**: `.github/workflows/documentation.yml`

### 問題

- `xcodebuild docbuild` 會為每個有 catalog 的模組各產生一個 `.doccarchive`；先前只取 `find … | head -1` 的第一個（通常是 HaishinKit），導致站台永遠只有 `haishinkit`，即使 App 的 catalog 已被建置。

### 修改

- 改為列出**所有** `.doccarchive`，逐一 `docc process-archive transform-for-static-hosting` 到 `site/<Module>`（`--hosting-base-path <repo>/<Module>`）。
- 產生根目錄 `index.html` 列出各模組連結（仿 HaishinKit 的 docc home 設計），不再寫死單一轉址。

---

## 2026.10.06 23:11 補上未版控的 DocC catalog（App 文件來源）

**類型**: 修復 · **檔案**: `liveAPP/Documentation.docc/liveAPP.md`

### 問題

- `liveAPP/Documentation.docc` 一直未被版控（untracked）。pbxproj 加上引用後，CI 的 `CompileDocumentation` 找不到該目錄，`docc convert` 失敗：`No documentation directory exists at '.../liveAPP/Documentation.docc'`。

### 修改

- 將 `liveAPP/Documentation.docc/liveAPP.md` 納入版控；此後 `docbuild` 應能產生 `documentation/liveapp`。

---

## 2026.10.06 22:23 接上 App 的 DocC catalog（project.pbxproj）

**類型**: 修復 · **檔案**: `liveAPP.xcodeproj/project.pbxproj`

### 問題

- `xcodebuild docbuild` 只產生相依套件（`haishinkit` 等）的模組文件；`liveAPP/Documentation.docc` 雖在 App 的檔案系統同步資料夾內，但 DocC 未將其視為 documentation catalog，故沒有 `documentation/liveapp` 頁面。

### 修改

- 為 `Documentation.docc` 加入明確的 `PBXFileReference`（`lastKnownFileType = folder.documentationcatalog`）與 `PBXBuildFile`，放進 `liveAPP` target 的 Sources 階段，並掛進主 group。

### 驗證

- 需 CI（macOS）確認 `docbuild` 產生 `documentation/liveapp`；若 pbxproj 格式導致建置失敗，revert 此 commit（獨立一顆）。

---

## 2026.10.06 21:58 DocC workflow 合併並修正 shell 與路徑

**類型**: 修復 · **檔案**: `.github/workflows/documentation.yml`, `.github/workflows/docc.yml`（刪除）, `Docs/development/README.md`

### 問題

- 新增的 `docc.yml` 與既有 `documentation.yml` 重複建置 DocC。
- 步驟摘要使用 bash 4 專屬的 `${VAR,,}`，在 runner 的 bash 3.2 觸發 `bad substitution` 而中斷。
- DocC 轉出的模組只有 `haishinkit`（App 的 `.docc` 未加入 Xcode 專案），卻寫死轉址到 `liveapp`，導致 Pages 404。

### 修改

- 刪除 `docc.yml`，改在既有 `documentation.yml` 一次完成：建置、保存 revision／Package.resolved／日誌、轉靜態站、打包 zip、部署 GitHub Pages。
- 摘要改用 `tr` 轉小寫（相容 bash 3.2）；根目錄轉址改為動態偵測模組目錄（優先 liveapp，否則取第一個）。
- 下載 artifact 改為 `documentation-<sha>.zip`（DocC 含 `:` 檔名，故以 zip 打包）。
- `Docs/development/README.md` 更新說明，並註明 App 文件需把 `.docc` 目錄加入 target。

**相關文件**: [development/README.md](Docs/development/README.md)

---

## 2026.10.06 21:52 記錄底層傳送診斷接口與接入待辦

- 底層 checkout 新增 transportDiagnostics()，修正傳送失敗計數及舊 completion 隔離。
- 更新功能索引與 TODO，App 套件鎖定／統一診斷 UI 仍待接入。
- 底層新增雙模組 DocC workflow，建置與部署待實跑。

## 2026.10.06 21:34 修正 DocC artifact 上傳（含冒號檔名）

**類型**: 修復 · **檔案**: `.github/workflows/docc.yml`, `Docs/development/README.md`

### 問題

- DocC workflow 在 `actions/upload-artifact` 失敗：DocC 會產生含 `:` 的符號檔名（如 `makebounds(_:).json`），上傳器不接受此類路徑（NTFS 不相容）。

### 修改

- 下載用 artifact 改為先 `zip` 整個 `site` 再上傳 `docc-site.zip`（單一檔，內含檔名不受限）；GitHub Pages 那條走 tar，不受影響。

**相關文件**: [development/README.md](Docs/development/README.md)

---

## 2026.10.06 21:27 檔案檢視 Markdown 排版與提示框

**類型**: 優化 · **檔案**: `Scripts/changelog/assets/markdown.js`、`highlight.js`、`file.*`、`Docs/development/README.md`

### 問題

- 開啟 `.md` 檔只能看原始文字，沒有排版；也沒有 `> [!TIP]` 之類提示框。

### 修改

- 新增零依賴 Markdown 渲染（`markdown.js`）：標題、巢狀清單、表格、程式碼區塊（沿用語法上色）、引言，以及 GitHub 提示框 `> [!NOTE]／[!TIP]／[!IMPORTANT]／[!WARNING]／[!CAUTION]`。
- 抽出共用語法上色到 `highlight.js`（來源逐行與程式碼區塊共用）。
- 檔案檢視開啟 `.md` 時**預設排版**，可一鍵切回原始碼；文件內相對連結改寫為站內檔案檢視連結。
- `Docs/development/README.md` 更新資產與檢視說明。

**相關文件**: [development/README.md](Docs/development/README.md)

---

## 2026.10.06 21:24 檔案檢視語法上色與 DocC CI

**類型**: 優化 · **檔案**: `Scripts/changelog/assets/file.*`, `Scripts/changelog/devindex.py`, `.github/workflows/docc.yml`, `Docs/development/README.md`

### 問題

- 檔案檢視只有統一白字，沒有語法上色，難以快速閱讀。
- DocC 文件需要 macOS，但專案沒有對應的 CI 產出流程。

### 修改

- 檔案檢視加入**零依賴**的 Swift／Markdown 語法上色：伺服器把每行代碼包進 `.code`，前端逐行掃描字串、註釋（含跨行）、數字、屬性／前置、關鍵字、型別與函式；深淺色各有色票。
- 行號改為 `.no` 連結、行容器 `.ln`，修正原本 `#src span` 會讓巢狀 token 變區塊的問題。
- 新增 `.github/workflows/docc.yml`：於 `xcode-27` 建 DocC、`transform-for-static-hosting`、上傳 `docc-site` artifact 並部署 GitHub Pages。

**相關文件**: [development/README.md](Docs/development/README.md)

---

## 2026.10.06 21:18 開發索引 API 掃描強化與 DocC 說明

**類型**: 優化 · **檔案**: `Scripts/changelog/devindex.py`, `Scripts/changelog/assets/dev.*`, `Docs/development/README.md`

### 問題

- API 宣告只收單行、只有 func／型別；屬性、init、多行簽名都漏掉，且名稱顯示為整行。
- 文件沒說清楚為何本機無法產生 DocC。

### 修改

- `scan_symbols` 改為：收錄 func／型別／extension／init／subscript 與「具存取修飾」的 var/let，附種類、名稱、多行簽名，註釋允許 `@屬性`／`#條件` 穿插。
- 開發索引卡片顯示種類標籤與等寬簽名（新增 `.sig` 樣式）。
- `Docs/development/README.md` 新增「文件（DocC）」段落：說明 DocC 無法在 Windows 產生（Apple SDK／.xcodeproj），以及 macOS/CI 以 `xcodebuild docbuild` 產出。

**相關文件**: [development/README.md](Docs/development/README.md)

---

## 2026.10.06 18:48 變更歷史工具拆模組並重做開發索引與深色模式

**類型**: 重構 · **檔案**: `Scripts/change_log.py`, `Scripts/dev_index.py`, `Scripts/changelog/*`, `Scripts/changelog/assets/*`

### 問題

- `change_log.py` 把解析、CLI、HTTP 與整頁 HTML/CSS/JS 全塞在一個檔（600+ 行），隨功能增加愈難維護、可讀性差。
- 開發索引沒有深色模式；API 宣告與檔案檢視頁顯示生硬（純 `<pre>`、無行號跳轉/高亮、無導覽）。

### 修改

- 拆成 `Scripts/changelog/` 套件：storage／devindex／server／cli／assets；`change_log.py`、`dev_index.py` 改為相容入口薄殼。
- 網頁資產移出 Python 字串，放到 `changelog/assets/`（`theme.css` 加上 index／dev／file 三組）；`assets.py` 提供讀取與 `{{key}}` 模板替換。
- 深色模式：共用 `theme.css` 色票 + `theme.js`（跟隨系統偏好、記在 localStorage）。
- 開發索引：API 註釋以 markdown 呈現、來源篩選、功能卡片與鎖定套件版面重整。
- 檔案檢視：行號就地跳轉與高亮、行號輸入、複製路徑、返回保留瀏覽位置。
- 每個模組補 docstring／註解；更新 `Docs/development/README.md` 與測試（新增 `/assets` 服務檢查）。

**相關文件**: [development/README.md](Docs/development/README.md)

---

## 2026.10.06 13:31 新增開發功能與 API 索引

- 原有變更工具新增功能接入、API 宣告、文件全文搜尋與近期 Git 改動入口。
- 加入功能清單、鎖定套件與 checkout 版本顯示、唯讀原始碼行號跳轉及 CI 驗證。
- 提供初始 DocC 目錄與手動建置 workflow，Apple SDK 文件建置待實跑。

**相關文件**：[開發索引](development/README.md)

## 2026.10.06 06:13 修正 SC 疊加上下顛倒與擷取來源轉置

**類型**: 修復 · **檔案**: `liveAPP/Capture/ScreenStreamVideoRotator.swift`, `liveAPP/Capture/ScreenCaptureSource.swift`

### 問題

- 輸出疊加（時間層）上下顛倒。
- 畫布已是 1920×1080，但畫面內容仍是直的（直的來源被塞進橫畫布）。

### 根因

- 疊加：`CGContext` 已翻轉 CTM 後再 `draw`，會把圖片連同座標一起上下顛倒（重複翻轉）。
- 內容：SC 擷取緩衝的寬高與輸出設定是轉置的（同 ReplayKit），先前以未轉置尺寸擷取，來源是橫的、內容被塞成直的。

### 修改

- 疊加：移除 CTM 翻轉，改把 `OverlayAnchor` 的左上 y 換算到左下再 `draw`。
- 擷取：左轉時以轉置尺寸設定 `SCStreamConfiguration.width/height`。
- 新增 `[CaptureFrame] size=WxH` 診斷（首幀／尺寸變化時輸出）。

**相關文件**: [screencapturekit-integration.md](Docs/screencapturekit-integration.md)

---

## 2026.10.06 05:13 移除 SC 推流閒置 keep-alive 幀泵

**類型**: 修復 · **檔案**: `liveAPP/Capture/ScreenCaptureSource.swift`

### 問題 - 可能造成影片破損/斷續

實機出現影片破損、斷續，疑似 keep-alive 合成 PTS 造成時間戳不連續（待隔離確認）。

### 修改 - 移除 ScreenSamplePump 的 keep-alive

回復為僅旋轉/疊加與 mailboxes；移除定時重播、相關欄位與 `keepAlive{}` 診斷。日後若要重做 idle 保活，需重新設計（PTS 對齊 host clock、不與真實幀競速）。

---

## 2026.10.06 05:00 修正 ScreenOverlayComposer 的 uiFontWeight 重複宣告

**類型**: 修復 · **檔案**: `liveAPP/Capture/ScreenOverlayComposer.swift`

### 問題 - CI 編譯失敗

`ScreenOverlayComposer.swift` 的 `private func uiFontWeight` 與 `OverlaySettingsView.swift` 既有的同名函式（internal）造成 invalid redeclaration。

### 修改 - 移除重複宣告，改用既有函式

移除本檔的 `uiFontWeight`，直接使用 `OverlaySettingsView.swift` 既有的 internal 版本。

---

## 2026.10.06 04:53 修正 SC 推流畫布寬高：改用 (odstW, odstH) 不轉置

**類型**: 修復 · **檔案**: `liveAPP/Capture/ScreenCaptureSource.swift`

### 問題 - 推流畫布變成 1080×1920（直的）

左轉後推流解析度變成 1080×1920，應為橫向 1920×1080。

### 根因 - 編碼畫布多了一次轉置

SC 擷取緩衝的寬高本身即與設定轉置（與 ReplayKit 相同），旋轉後已對上 (odstW, odstH)；先前又交換畫布，導致輸出變直的。

### 修改 - 編碼畫布直接用 size，與 ReplayKit encoder 慣例一致

`video.videoSize = size`（ReplayKit `SampleHandler` 的 encoderW/H = ODWidth/ODHeight，不轉置）。

**相關文件**: [screencapturekit-integration.md](Docs/screencapturekit-integration.md)

---

## 2026.10.06 04:45 SC 推流輸出時間疊加（影像合成器）

**類型**: 新增 · **檔案**: `liveAPP/Capture/ScreenOverlayComposer.swift`（新）, `liveAPP/Capture/ScreenStreamVideoRotator.swift`, `liveAPP/Capture/ScreenCaptureSource.swift`, `liveAPP/Capture/CaptureCoordinator.swift`

### 問題 / 需求 - SC 推流沒有輸出疊加

ReplayKit 路徑的輸出疊加（時間層）由 extension 的 Metal renderer 處理；ScreenCaptureKit 路徑完全沒有疊加、也無自訂畫布。

### 修改 - 影像 worker 加上 CoreGraphics 疊加階段

- 新增 `ScreenOverlayComposer`：依 `OverlaySceneConfig`（時間層）raster 出疊加圖，每秒或設定變更重建；座標採左上原點（與 `OverlayAnchor` 一致）。
- `ScreenStreamVideoRotator` 改為同時處理旋轉（可選）與疊加：CoreImage 旋轉後，以左上原點 CTM 把疊加圖畫進 BGRA 緩衝；無旋轉且無疊加時原樣返回。
- `ScreenSamplePump` 一律建立帶 overlay 的合成器；`CaptureCoordinator` 說明更新。

**相關文件**: [screencapturekit-integration.md](Docs/screencapturekit-integration.md)

**待驗證**: 疊加的垂直錨點（CoreGraphics 翻轉 CTM）與效能需實機確認。

---

## 2026.10.06 04:26 推流閒置 keep-alive 幀泵（重播最後一格）

**類型**: 新增 · **檔案**: `liveAPP/Capture/ScreenCaptureSource.swift`

### 問題 - 畫面靜止時 ScreenCaptureKit 不送視訊

SC 只在畫面有變化時產生 `.complete` 幀；閒置時沒有視訊封包，留下大 PTS 缺口，部分播放器在畫面恢復時卡住或 seek。

### 修改 - 閒置時以 15fps 重播最後一格

- `ScreenSamplePump` 快取最後一格 `.complete` 的 CMSampleBuffer（保留像素、不複製）。
- Timer 每 1/15 秒檢查：距上次真實幀超過一個間隔才補一格；有真實幀時完全不動作。
- 補格以新、單調遞增的 PTS 重建 sample（`CMSampleBufferCreateReadyWithImageBuffer`），並走同一旋轉 worker。
- `[CaptureSource]` 診斷新增 `keepAlive{sent=…}`。

**相關文件**: [screencapturekit-integration.md](Docs/screencapturekit-integration.md)

---

## 2026.10.06 04:20 修正推流左轉畫面尺寸與多軌混音無輸出（HaishinKit fork）

**類型**: 修復 · **檔案**: `liveAPP/Capture/ScreenCaptureSource.swift`, `Package.resolved`, HaishinKit fork（`AudioMixerSettings.swift`／`AudioMixerByMultiTrack.swift`／`AudioPipelineDiagnostics.swift`）

### 問題 - 左轉後畫面縮小；App／麥克風音訊完全沒送

開啟「推流左轉 90°」後畫面轉正但縮成中間一小條；ScreenCaptureKit 推流完全沒有音訊封包（`mixed=0 delivered=0`）。

### 根因

- 影片：旋轉器輸出 1080×1920，但編碼畫布固定 1920×1080 + letterbox，豎畫面被塞進橫畫布而縮小。
- 音訊：SC 的 float32 planar 音訊使 mixer 輸出格式推導為 non-interleaved，`MultiChannelMixer`／`GenericOutput` 初始化／render 失敗 → `outputNode` 為 nil、mixer 永不輸出；錯誤又被 `AudioCaptureUnit` 吞掉。

### 修改

- `ScreenCaptureSource`：編碼畫布跟著旋轉後尺寸（`rotateLeft` 時交換寬高）。
- fork `AudioMixerSettings.makeOutputFormat`：輸出格式一律 interleaved。
- fork `AudioPipelineDiagnostics`：新增 `mixerReady` 與 `lastError`；`[CaptureAudioPipeline]` 日誌新增 `ready=`／`error=`。
- 更新 `Package.resolved` 指向 fork `1b4650c6`。

**相關文件**: [screencapturekit-integration.md](Docs/screencapturekit-integration.md)

---

## 2026.10.06 03:07 加入推流 AAC 碼率選項

- 音訊設定提供自動、128、96、64 kbps；預設自動，下次開播生效。
- ReplayKit／ScreenCaptureKit 共用偏好與解析規則，維持 AAC LC；不影響原生本地錄影。
- ReplayKit 統計改讀已套用碼率，ScreenCaptureKit 目標碼率顯示與日誌同步，補齊三語說明。

## 2026.10.06 02:56 ScreenCaptureKit 推流左轉與音訊、連線診斷

- 加入預設左轉 90° 的推流像素修正，可在停止後關閉；本地錄影方向獨立設定。
- 記錄來源音訊 ASBD、PCM 可讀性、Mixer 產出及 RTMP 音訊封包，補齊先前被篩掉的音訊診斷。
- 主頁顯示 RTMP 連線階段、實際編碼器格式、設定碼率及音訊封包等待／缺失／過期狀態，補上三語文字。
- 無聲根因與 Apple SDK 建置、實機方向／音訊仍待驗證；不將來源 accepted 誤認為成功送音訊。

**相關文件**：[ScreenCaptureKit 接入](screencapturekit-integration.md)

## 2026.10.05 23:53 CI 允許套件外掛，修正 HaishinKit 外掛驗證失敗

**類型**: 修復 · **檔案**: `.github/workflows/unit-tests.yml`, `.github/workflows/main.yml`

### 問題 - CI 建置中止於 HaishinKitRevisionPlugin

`Plugin "HaishinKitRevisionPlugin" from package "HaishinKit" must be enabled before it can be used`。

### 根因 - 套件 build tool plugin 需互動式信任，非互動 CI 無法回應

HaishinKit（fork）提供 build tool plugin；xcodebuild 在非互動環境要求先「enable」外掛才允許執行。

### 修改 - 所有 xcodebuild 呼叫加上 -skipPackagePluginValidation -skipMacroValidation

unit-tests.yml 測試、main.yml fast build／clean／archive 皆加旗標；跳過外掛／巨集的簽章驗證，但仍會執行外掛（保留 HaishinKit revision 注入）。

**相關文件**: [unit-tests.yml](.github/workflows/unit-tests.yml), [main.yml](.github/workflows/main.yml)

---

## 2026.10.05 22:03 自動產生 kHaishinKitRevision（SwiftPM build tool plugin）

**類型**: 優化 · **檔案**: `Package.resolved`

### 問題 - 原本是手動常數，會與實際 HEAD 漂移（App log 曾顯示舊值）

Docs 宣稱的 CI 自動流程並不存在。

### 修改 - SwiftPM build tool plugin：RevisionTool 跑 `git rev-parse --short HEAD`

HaishinKitRevisionPlugin 產生常數並掛到 HaishinKit target。

**相關文件**: [自動產生 kHaishinKitRevision](https://github.com/TwhomeGH/HaishinKitFixSwfit/blob/main/CHANGES.md#64-%E8%87%AA%E5%8B%95%E7%94%A2%E7%94%9F-khaishinkitrevisionswiftpm-build-tool-plugin)

---

## 2026.10.05 21:52 修正 RTMP 重連：S2 之後同段資料被丟棄導致 connect 永不 resolve

**類型**: 修復 · **檔案**: `Package.resolved`

### 根因 - `RTMPHandshake` 有兩種不一致的消費語意——c2packet() 用

removeSubrange 移除 S0+S1，但 S2 只用「buffered 數量」判斷、從不移除

而 RTMPConnection.listen 的 .ackSent 轉到 .handshakeDone 後用的是另一個 buffer。

於是任何與 S2 同一段 TCP read 抵達的位元組（伺服器緊接送出的 SetChunkSize / WindowAckSize / SetPeerBandwidth

或與 S2 合併的 connect `_result`）都被靜默丟棄，connect continuation 永不 resume

伺服器等不到 createStream/publish，數秒後關閉連線，recv loop EOF → close() 對 pending

operation 回填合成的 Connect.Failed，病因被掩蓋。

### 修改 - `RTMPSocket` 新增 `didEndStream`（乾淨 EOF，content == nil）並留下日誌

- close() 在未連線階段以真正的底層原因回填 pending operation
- （`.socketErrorOccurred(NWError / .endOfStream)`），不再合成空白 `Connect.Failed`。

**相關文件**: [RTMP 重連：S2 之後同段資料被丟棄](https://github.com/TwhomeGH/HaishinKitFixSwfit/blob/main/CHANGES.md#61-%E4%BF%AE%E6%AD%A3-rtmp-%E9%87%8D%E9%80%A3s2-%E4%B9%8B%E5%BE%8C%E5%90%8C%E6%AE%B5%E8%B3%87%E6%96%99%E8%A2%AB%E4%B8%9F%E6%A3%84%E5%B0%8E%E8%87%B4-connect-%E6%B0%B8%E4%B8%8D-resolve)

---

## 2026.10.05 19:11 本機錄影可選編碼（H.264／HEVC／AV1，依裝置能力）

**類型**: 新增 · **檔案**: `liveAPP/Capture/RecordingVideoCodec.swift`, `liveAPP/Capture/ScreenRecordingSession.swift`, `liveAPP/Capture/CaptureCoordinator.swift`, `Docs/screencapturekit-integration.md`

### 問題 / 需求 - ScreenCaptureKit 錄影無法選擇編碼

原本硬編 H.264，無法依需求改用 HEVC 或 AV1。

### 根因 - 錄製編碼固定為 .h264

### 修改 - 以執行期可用清單提供編碼偏好

- 新增 `RecordingVideoCodec`（auto/h264/hevc/av1）與持久化 `recordingVideoCodec`。
- `ScreenRecordingCodecSupport` 以 `SCRecordingOutputConfiguration.availableVideoCodecTypes` 解析：auto 優先 HEVC、不支援時退回 H.264，並回報實際採用編碼。
- 擷取頁新增「錄影編碼」Picker，選項依執行期清單產生並標示不可用者（AV1 需裝置支援）。
- 文件補充編碼選擇與方向修正的交互。

**相關文件**: [screencapturekit-integration.md](Docs/screencapturekit-integration.md)

---

## 2026.10.05 18:38 外部音訊播放時跳過還原並開放 RTMP 握手診斷

**類型**: 修復／診斷 · **檔案**: `liveAPP/Capture/ScreenCaptureSource.swift`

### 修改 - 依實機時序避免收尾切換音訊 category

- 其他音訊仍在播放時保留現有混音 session，不立即或延遲切換 category，也不重新啟用／停用；後續交由真正需要音訊的功能管理。
- 新增 restore.deferredOtherAudioPlaying 紀錄；此策略暫時保留 playAndRecord 設定，並非完整還原原 category。
- 放行遮蔽後的 TCP、RTMP 握手、connect 回應與重連事件，補足先前只轉送 VideoQueue 的缺口。
- 目前可確認 1936 明確指定且連線 15 秒逾時，尚不能據此判定網路或伺服器根因。

---

## 2026.10.05 17:44 修正錄影收尾閉包的明確 self 存取

**類型**: 修復 · **檔案**: `liveAPP/Capture/ScreenRecordingSession.swift`

### 修改 - 明確標示非同步工作捕獲語意

- 為方向收尾 Task 內的 orientation、id、policy 與 complete 補上 self，修正 CI 回報的 Swift 6 捕獲語意警告。
- 保留既有強捕獲、背景到期取消與原片保留行為。
- Swift 語法與差異格式檢查通過；完整 Apple SDK 型別檢查待 CI 驗證。

---

## 2026.10.05 16:59 修正日誌併發與舊版 iOS 集合相容性警告

**類型**: 修復 · **檔案**: `liveAPP/liveAPPApp.swift`、`liveAPP/FileLogView.swift`、`liveAPP/Capture/RecordingOrientationCorrector.swift`

### 修改 - 明確隔離與相容操作

- AppLogPersister 明確宣告以序列佇列保護狀態的 Sendable 契約；統計讀寫另外加鎖，避免跨執行緒競爭。
- 最新日誌定位改用 Array.indices.last，避免依賴 iOS 26 才提供的 EnumeratedSequence BidirectionalCollection 遵循。
- 移除 AVMutableCompositionTrack 的無效條件轉型。
- Swift 語法與差異格式檢查通過；完整 Apple SDK 警告驗收仍需 CI。

---

## 2026.10.05 16:48 本地錄影加入詳細資訊與直接碼率分析

**類型**: 功能／修復 · **檔案**: `liveAPP/Capture/RecordingLibrary.swift`、`liveAPP/Capture/RecordingDetailsView.swift`、`liveAPP/VideoBitrateView.swift`

### 修改 - 以實際完成檔案查看資訊

- 已完成錄影提供詳細資訊與直接分析碼率，包含方向矩陣前後尺寸、標稱 FPS、估計影像碼率與整檔平均。
- 快速資訊按需讀取與快取，完整分析沿用既有分析器。
- 修正分析頁將非暫存來源加入清理清單的問題，避免關閉分析時刪除原片。
- 新增三語資訊標籤與文件；Apple SDK 建置與實際影片驗收待確認。

---

## 2026.10.05 16:43 避免擷取失敗收尾切回排他音訊設定

**類型**: 修復 · **檔案**: `liveAPP/Capture/ScreenCaptureSource.swift`

### 修改 - 保持音訊混音並補充收尾時序

- 背景麥克風保留 playAndRecord／mixWithOthers，移除強制 defaultToSpeaker。
- 收尾只還原可混音 category；原設定為排他類型時使用 playback／mixWithOthers，移除 duckOthers 與 spoken-audio 中斷選項。
- 不停用或重新啟用 PiP／TTS 共用 session；若設定已被其他使用者改動則跳過還原。
- 記錄音訊啟動、系統停止前後、還原、中斷通知及路由原因；不記錄裝置名稱。
- 此為 App 端干擾風險修正；外部影片暫停的實際觸發點仍需實機回歸確認。

---

## 2026.10.05 16:38 補充 ScreenCaptureKit 推流目標與連接埠日誌

**類型**: 改進 · **檔案**: `liveAPP/Capture/ScreenCaptureSource.swift`、`liveAPP/Capture/CaptureErrorDiagnostics.swift`

### 修改 - 連線前顯示實際目標解析

- CaptureEndpoint 記錄 session、HaishinKit 傳輸、scheme、host、port、port 是否明確指定及 appPath。
- 不輸出使用者憑證、query 與串流金鑰；新增 1936 明確指定、預設 port、錯誤網址與憑證遮蔽檢查。

---

## 2026.10.05 16:35 恢復日誌跨筆框選並標示日誌模式

**類型**: 改進 · **檔案**: `liveAPP/FileLogView.swift`、`liveAPP/Localizable.xcstrings`

### 修改 - 連續原文選取與來源說明

- 新增目前篩選頁面的固定原文快照，透過單一 UITextView 跨多筆框選複製。
- 開啟框選時暫停追尾，快照不受新日誌刷新影響。
- 來源選擇上方新增日誌模式標題與用途說明，補齊三語文字。
- Swift 語法與字串格式檢查通過；系統選取把手互動仍待實機驗證。

---

## 2026.10.05 12:24 修正日誌頁 iOS 16.6 建置相容性

**類型**: 修復 · **檔案**: `liveAPP/FileLogView.swift`

### 修改 - 移除 iOS 17 限定的捲動 API

- 使用 ScrollViewReader 取代 scrollTargetLayout／scrollPosition，不提高最低系統版本。
- 透過可見列位置記錄閱讀行號，保留歷史定位、切頁返回與最新追尾。
- Windows Swift 語法檢查通過；Apple SDK 可用性與 iOS 16.6 捲動操作待 CI／實機確認。

---

## 2026.10.05 12:06 日誌頁改以主檔案分頁讀取歷史

**類型**: 改進 · **檔案**: `liveAPP/FileLogView.swift`、`liveAPP/LogFileReader.swift`、`liveAPP/liveAPPApp.swift`

### 修改 - 統一檔案歷史與最新內容入口

- 以主 log.txt 為準，每頁 200 行，支援較早／較新、回到最新與檔案行號。
- 保留本次 App 執行期間的閱讀位置與篩選；移除背景清空歷史行為及舊記憶體顯示入口。
- 新增完整檔案搜尋、進度、取消與結果前後文；最多 500 筆結果，單頁讀取上限 1 MiB。
- 清空需確認，索引在裁切／替換時失效；沿用既有檔案保留上限。
- 檔案追加、裁切、中文跨區塊及空檔案核心檢查通過，實機互動待驗收。

**相關文件**: [日誌頁](log-view.md)

---

## 2026.10.05 09:35 改善日誌頁分類、篩選與閱讀操作

**類型**: 改進 · **檔案**: `liveAPP/ContentView.swift`、`liveAPP/LogPresentation.swift`、`liveAPP/liveAPPApp.swift`

### 修改 - 等級色彩與模組標籤

- 加入等級／模組篩選、關鍵字與 session 搜尋及篩選原文複製。
- 以文字與符號搭配紅／橙／綠顏色，保留文字選取和批次追加。
- 將自動追尾門檻改為距底部 60 點，選取與拖曳期間不強制捲動。
- 新增三語工具列及分類測試；實機閱讀、配色與大量日誌待驗收。

**相關文件**: [日誌頁](log-view.md)

---

## 2026.10.05 09:31 補足 ScreenCaptureKit 推流失敗診斷

**類型**: 改進 · **檔案**: `liveAPP/Capture/ScreenCaptureSource.swift`、`liveAPP/Capture/CaptureErrorDiagnostics.swift`

### 修改 - 分開擷取與發布狀態並保留錯誤原因

- 以 session 串接 RTMP connect／publish 階段、發布成功與失敗，避免將擷取中誤認為推流成功。
- 記錄錯誤型別、domain／code、描述、原因及底層錯誤鏈；先遮蔽已知金鑰、網址與憑證參數。
- 補充選擇器、音訊設定、管線建立、錄影掛載及系統停止擷取的失敗階段。
- 加入診斷遮蔽、錯誤鏈、具名錯誤與長度限制測試；原錯誤碼 5 仍需新日誌重現定位。

---

## 2026.10.05 09:28 修正錄影左右方向、加入方向選項並穩定主頁切換

**類型**: 修復／改進 · **檔案**: `liveAPP/Capture/`、`liveAPP/ContentView.swift`、`liveAPP/Localizable.xcstrings`

### 修改 - 依實測修正方向並提供選擇

- 自動模式交換來源方向 6／8 的輸出映射，修正範例影片旋轉後上下顛倒。
- 新增不修正、左右 90° 與 180°，在開始擷取時固定；手動方向以原始像素為基準。
- 固定主頁雙欄寬度與頂部對齊，取消切換的隱含動畫，選擇器明確採選單樣式。
- 主頁主要控制、擷取模式與方向選項加入繁中／英文／日文資源。
- 補充自動／手動策略核心測試；Apple SDK 匯出與實機版面仍待回歸。

**相關文件**: [ScreenCaptureKit](screencapturekit-integration.md)、[主頁操作](home-layout.md)

---

## 2026.10.05 03:17 TTS 匯入提示改行內顯示；.gitignore 忽略 CI 產物

**類型**: 修復 · **檔案**: `liveAPP/TTSSettingsView.swift`, `.gitignore`

### 問題 - TTS 匯入若 modal 呈現被吞掉就完全沒回饋

匯入結果只以 sheet／alert 呈現，一旦被系統吞掉（選完檔案無反應）就無法得知成功或錯誤。

### 根因 - 回饋完全依賴 modal 呈現

### 修改

- FilterSettingsView 於輸入區加入行內 `notice` 文字（成功／錯誤皆顯示），不再只依賴 alert。
- `.gitignore` 忽略 CI 產物（`build/`、`TestResults/`、`xcodebuild.log`、`xcodebuild-summary.md`），避免 BuildInfo 誤報「有未提交修改（未追蹤 N）」。

**相關文件**: [TTSSettingsView.swift](liveAPP/TTSSettingsView.swift)

---

## 2026.10.05 03:16 修正側載無 App Group 導致螢幕擷取被鎖住

**類型**: 修復 · **檔案**: `SharedCapture/CaptureLease.swift`, `liveAPP/Capture/CaptureCoordinator.swift`

### 問題 - 側載時擷取來源選單變灰、也看不到原因

側載（無 App Group）時「螢幕擷取方式」整排變灰；即使 ScreenCaptureKit 判斷為不支援，也沒有任何原因。

### 根因 - CaptureLease.acquire() 在無 App Group 時丟錯

`acquire()` 需要 `group.nuclear.liveAPP` 容器，側載沒有 → 丟錯 → `CaptureSelectionView` 的 `anotherCapture` 恆為 true → `controlsDisabled` 讓整個 Picker 停用；此停用先前不顯示任何原因。同理 `SampleHandler.broadcastStarted` 也會因 acquire 失敗而 `finishBroadcastWithError`。

### 修改 - 無 App Group 退回本地鎖 + 顯示停用原因

- `CaptureLease.acquire()`：有 App Group 用共享鎖；否則退回 app 暫存目錄（僅程序內意義），不再丟錯。
- `backendPicker`：無支援原因時，若 `anotherCapture`／`isBusy` 也顯示對應原因。

**相關文件**: [CaptureLease.swift](SharedCapture/CaptureLease.swift)

---

## 2026.10.05 02:47 修正 TTS 過濾 JSON 匯入：選完檔案無反應

**類型**: 修復 · **檔案**: `liveAPP/TTSSettingsView.swift`

### 問題 - 匯入 JSON 開出檔案選擇器後無法進到預覽

選好檔案後畫面沒反應，預覽 sheet 與錯誤 alert 都不出現。

### 根因 - 檔案選擇器收合與下一個 modal 同執行週期，SwiftUI 吞掉後者

`.fileImporter` 完成回呼在同一執行週期就設定 `preview`／`notice` 去開 sheet／alert；iOS 檔案選擇器（UIKit 模態）收合時再要求呈現下一個 modal 會被丟棄，連錯誤也被吞掉，畫面看似「選完就沒反應」。

### 修改 - 選擇器收合後再切換呈現狀態

- 以 `handleImport(_:)` 集中處理，透過 `Task { @MainActor in }` ＋短延遲，在選擇器收合後才設定 `preview`／`notice`（同時確保主執行緒更新）。
- 讀檔抽成 `readConfiguration(from:)`（security-scoped 存取 + 2 MiB 上限不變）。

**相關文件**: [TTSSettingsView.swift](liveAPP/TTSSettingsView.swift)

---

## 2026.10.05 02:31 ScreenCaptureKit 不可用原因診斷與擷取畫面重整

**類型**: 優化 · **檔案**: `liveAPP/Capture/CaptureCoordinator.swift`

### 問題 - 實機選項變灰卻不知原因；擷取設定畫面可讀性差

ScreenCaptureKit 灰掉時只有籠統說明，難判斷是建置旗標、SDK 或裝置限制；`CaptureSelectionView` 條件堆疊、狀態散落。

### 根因 - 可用性只回 bool、無診斷；視圖為大型內聯 VStack

### 修改 - 提供不可用原因並抽出子視圖

- 新增 `screenCaptureUnavailableReason`（模擬器／macCatalyst／未定義旗標／無模組／iOS<27／`isAvailable == false` 各有明確訊息），`screenCaptureSupported` 由其推導；UI 於選項下方顯示原因。
- CaptureSelectionView 抽出 `backendPicker`／`screenCaptureKitOptions`／`statusLine` 與計算屬性，狀態合併一行，輪詢移入 `watchCaptureLease()`。

**相關文件**: [CaptureCoordinator.swift](liveAPP/Capture/CaptureCoordinator.swift)

---

## 2026.10.05 02:30 測試 target deployment 提升至 17.0

**類型**: 修復 · **檔案**: `liveAPP.xcodeproj/project.pbxproj`

### 問題 - 連結 XCTest/Testing 版本不符警告

`building for iOS-simulator-16.6, but linking with dylib '@rpath/XCTest.framework/XCTest' which was built for newer version 17.0`（Testing、libXCTestSwiftSupport 同）。

### 根因 - 測試 target 的 deployment target(16.6) 低於測試框架(17.0)

### 修改 - liveAPPTests／liveAPPUITests deployment 改 17.0

- 兩個測試 target（Debug／Release）`IPHONEOS_DEPLOYMENT_TARGET` 16.6 → 17.0；App 本體維持 16.6。

**相關文件**: [project.pbxproj](liveAPP.xcodeproj/project.pbxproj)

---

## 2026.10.05 02:29 BuildInfo 原始碼狀態加入未追蹤/已修改計數

**類型**: 優化 · **檔案**: `Scripts/build_info.py`, `Scripts/test_build_info.py`, `liveAPP/BuildInformation.swift`

### 問題 - 「有未提交修改」無法區分原始碼修改與未追蹤檔案

`appDirty` 只是一個 bool（`git status --porcelain` 非空），把未追蹤檔也算成「有未提交修改」，容易誤報。

### 根因 - git 狀態被壓成單一布林

`snapshot()` 只回傳 dirty bool，未保留未追蹤／已修改的數量。

### 修改 - 保留彈性，另存計數

- build_info.py：`snapshot()` 回傳 `(revision, dirty, untracked, modified)`，逐行以 `??` 分類；BuildInfo.json 新增 `appUntrackedCount`／`appModifiedCount` 與 HaishinKit checkout 對應欄位（bool 保留，向後相容）。
- BuildInformation.swift：新增計數欄位，`modifications(dirty:untracked:modified:)` 顯示如「有未提交修改（已追蹤 2、未追蹤 5）」。
- 測試同步更新（6/6 通過）。

**相關文件**: [build_info.py](Scripts/build_info.py)

---

## 2026.10.05 01:39 移除 ScreenCaptureKit iOS 不可用的 SCStreamConfiguration 屬性

**類型**: 修復 · **檔案**: `liveAPP/Capture/ScreenCaptureSource.swift`, `Docs/screencapturekit-integration.md`

### 問題 - 裝置 archive 續報多個 SCStreamConfiguration 屬性不可用

iOS 編譯接連報 `pixelFormat`、`minimumFrameInterval`、`queueDepth`、`captureMicrophone` 在 iOS 不可用。

### 根因 - 這些屬性在 SDK header 標記 API_UNAVAILABLE(ios)

ScreenCaptureKit 在 iOS 的 `SCStreamConfiguration` 只有部分屬性可用（`width`／`height`／`capturesAudio` 可用），其餘 `pixelFormat`／`minimumFrameInterval`／`queueDepth`／`captureMicrophone`／`scalesToFit`／`preservesAspectRatio` 皆 macOS／Mac Catalyst 專用。Apple 文件 metadata 未反映此限制，以 SDK header 為準。

### 修改 - iOS 只設定可用屬性並更新文件

- ScreenCaptureSource.swift：移除 pixelFormat／minimumFrameInterval／queueDepth／captureMicrophone，只留 width／height／capturesAudio；麥克風改由 picker 的 `showsMicrophoneControl` 控制（已設）。
- 文件：SDK 條件新增 iOS 屬性限制說明；擷取頻率與 queueDepth 描述改為 iOS 由系統決定。

**相關文件**: [ScreenCaptureSource.swift](liveAPP/Capture/ScreenCaptureSource.swift)

---

## 2026.10.05 01:36 主建置流程 (main.yml) 也接上日誌摘要

**類型**: 優化 · **檔案**: `.github/workflows/main.yml`, `Scripts/ci_test_summary.py`

### 問題 - 發布建置的錯誤分類薄弱，仍需人工翻 log

`main.yml` 只以 grep 粗略抽取 error／warning，archive 階段完全沒有摘要；build 失敗時仍得從整包 log 找。

### 根因 - 摘要工具只接在 unit-tests workflow

### 修改 - main.yml 兩階段（fast build、archive）都接上摘要工具

- Fast compile 後（`if: always`）以 `ci_test_summary.py` 摘要 `xcodebuild.log`，取代原 grep 抽取。
- Archive 指令改 `tee build/archive.log`（`set -o pipefail` 保留失敗碼），archive 後（`if: always`）摘要 `archive.log`。
- `ci_test_summary.py` 增援「The following build commands failed:」區塊與 `ARCHIVE FAILED` 結束條件；無測試結果時不顯示 Tests 段。

**相關文件**: [main.yml](.github/workflows/main.yml)

---

## 2026.10.05 01:18 測試 target 停止連結 HaishinKit，修正重複 ObjC 類別

**類型**: 修復 · **檔案**: `liveAPP.xcodeproj/project.pbxproj`

### 問題 - 單元測試執行時 HaishinKit 類別重複載入

`Class _TtC10HaishinKit… is implemented in both …PackageFrameworks/HaishinKit…framework and …liveAPP.debug.dylib`，官方警告可能導致 spurious casting failures 與神秘崩潰。

### 根因 - 測試 target 多餘連結 HaishinKit

`liveAPPTests`（hosted，測試 bundle 會載入 app 行程）與 `liveAPPUITests` 從未 `import HaishinKit`，卻在 Frameworks 與 packageProductDependencies 連結它；執行時與 app 既有的 HaishinKit 同時載入 → 同名 ObjC 類別兩份。

### 修改 - 從測試 target 移除 HaishinKit

- 移除 `liveAPPTests`／`liveAPPUITests` 的 Frameworks 項目與 packageProductDependencies，並清掉孤兒 `PBXBuildFile`／`XCSwiftPackageProductDependency`。
- `liveAPP` 與 `ReplyKIT` 保留（真正需要）。

**相關文件**: [project.pbxproj](liveAPP.xcodeproj/project.pbxproj)

---

## 2026.10.05 01:17 CI 單元測試日誌摘要（顏色、擷取 warn 與 fail）

**類型**: 優化 · **檔案**: `Scripts/ci_test_summary.py`, `.github/workflows/unit-tests.yml`

### 問題 - CI 日誌冗長，warn／fail／測試清單需人工翻找

單元測試的原始 xcodebuild 輸出與日誌混雜，難以快速看出哪裡 warning、哪裡失敗、有哪些測試。

### 根因 - 無摘要步驟，原始輸出直接呈現

### 修改 - 新增零依賴摘要工具並接進 workflow

- 新增 `Scripts/ci_test_summary.py`：解析 `tests.log`，輸出彩色且可摺疊（`::group::`）的 Errors／Warnings／Tests 摘要；compile error 發 `::error file=,line=` 註解、失敗測試發 `::error::`，warnings 依訊息去重計數並附代表位置。
- `unit-tests.yml` 於測試後（`if: always()`）執行，並輸出 `TestResults/summary.md` 至 `$GITHUB_STEP_SUMMARY`（隨 artifact 上傳）。

**相關文件**: [ci_test_summary.py](Scripts/ci_test_summary.py)

---

## 2026.10.05 01:16 修正 Socket 捕捉警告與 ScreenCaptureKit iOS 不可用屬性

**類型**: 修復 · **檔案**: `liveAPP/Socket.swift`, `liveAPP/Capture/ScreenCaptureSource.swift`

### 問題 - Xcode 27 警告與裝置 archive 編譯失敗

`#ImplicitStrongCapture`（Socket.swift 外層隱式強捕捉 self 與內層 `[weak self]` 不一致）、`#SendableClosureCaptures`（於 `@Sendable` 閉包強捕捉非 Sendable 的 SocketServer）；裝置 archive 另報 `scalesToFit`／`preservesAspectRatio` 在 iOS 不可用。

### 根因 - 捕捉所有權不一致與 macOS 專用屬性

外層閉包隱式強捕捉、內層顯式弱捕捉即警告；`SocketServer` 非 Sendable 被 `@Sendable` 閉包強捕捉；`SCStreamConfiguration` 的 `scalesToFit`／`preservesAspectRatio` 標記 `API_UNAVAILABLE(ios)`，而該檔為 iOS 專用。

### 修改 - 明確捕捉、標記 Sendable、移除 iOS 不可用屬性

- Socket.swift：外層 `queue.async` 改 `{ [self] in }`（×2）；`class SocketServer` 加 `@unchecked Sendable`。
- ScreenCaptureSource.swift：移除 `config.scalesToFit` / `config.preservesAspectRatio`（iOS 以 width/height 決定輸出尺寸）。

**相關文件**: [Socket.swift](liveAPP/Socket.swift), [ScreenCaptureSource.swift](liveAPP/Capture/ScreenCaptureSource.swift)

---

## 2026.10.05 01:05 修正 SampleHandler 的 ImplicitStrongCapture 警告

**類型**: 修復 · **檔案**: `ReplyKIT/SampleHandler.swift`

### 問題 - 直播啟動 Task 內外捕捉所有權不一致

`Task(priority: .medium)` 外層隱式強捕捉 `self`，內層 `onPageStateChanged`／`onAudioConfigChanged` 用 `[weak self]`，觸發 `#ImplicitStrongCapture`（2 處）。

### 根因 - 外層隱式強捕捉與內層顯式弱捕捉並存

新版 Swift 對閉包所有權一致性更嚴格，隱式強與顯式弱並存即警告。

### 修改 - 外層明確 [self]

- `Task(priority: .medium) {` 改為 `Task(priority: .medium) { [self] in`；內層 `[weak self]` 保留（閉包由 SocketClient 單例長期持有，維持弱引用避免跨場次洩漏）。

**相關文件**: [SampleHandler.swift](ReplyKIT/SampleHandler.swift)

---

## 2026.10.05 00:50 修正 Swift Testing #expect 無法呼叫 mutating 方法

**類型**: 修復 · **檔案**: `liveAPPTests/CaptureSessionTests.swift`

### 問題 - CI 編譯測試檔失敗 13 個錯誤

`#expect` 內呼叫 mutating 方法報 `Cannot use mutating member on immutable value: '$0' is immutable`（13 處）。

### 根因 - #expect 巨集以不可變方式捕捉運算式

Swift Testing 的 `#expect(expr)` 會把 expr 包進閉包並以不可變方式捕捉；expr 為 `mutating` 呼叫（`CaptureSessionState.transition/begin`、`LocalRecording.transition`）時即失敗。先前 CI 卡在更早階段（Metal／ScreenCaptureKit／警告），未曾編到此檔才未提早顯現。

### 修改 - 先取出結果再 #expect

- CaptureSessionTests 5 個測試函式、13 個 `transition` 呼叫改為 `let x = …; #expect(x)`，另將 `state.begin()` 一併提出。

**相關文件**: [CaptureSessionTests.swift](liveAPPTests/CaptureSessionTests.swift)

---

## 2026.10.05 00:19 ScreenCaptureKit 改為實機限定，修正模擬器連結失敗

**類型**: 修復 · **檔案**: `liveAPP.xcodeproj/project.pbxproj`, `liveAPP/Capture/CaptureCoordinator.swift`, `liveAPP/Capture/ScreenCaptureSource.swift`, `liveAPP/Capture/ScreenRecordingSession.swift`

### 問題 - CI 於 iOS Simulator 連結失敗

單元測試建置 App 時報 `Framework 'ScreenCaptureKit' not found`、連結器 exit 1，測試取消。

### 根因 - ScreenCaptureKit 在 iOS 為實機限定，模擬器 SDK 不含此框架

Apple 文件載明 ScreenCaptureKit 於 iOS 27 需實機（sample「requires a device running iOS 27」）；iPhoneSimulator 27 SDK 沒有 ScreenCaptureKit.framework。專案原本對 `sdk=iphonesimulator27.*` 也下 `-weak_framework ScreenCaptureKit`，而 `-weak_framework` 仍要求框架存在，故連結失敗。

### 修改 - 只在 iPhoneOS 27 定義旗標與弱連結，原始碼排除模擬器

- pbxproj：`SCREEN_CAPTURE_KIT_IOS27` 與 `-weak_framework ScreenCaptureKit` 只保留 `sdk=iphoneos27.*`，移除 `iphonesimulator27.*`（Debug／Release 各一組）。
- 原始碼 5 處 `#if` 加 `&& !targetEnvironment(simulator)`（CaptureCoordinator ×3、ScreenCaptureSource、ScreenRecordingSession）。
- 文件與 TODO 更新：說明實機限定；ScreenCaptureKit 的 Apple SDK 編譯改由發布流程的裝置 archive 涵蓋。

**相關文件**: [screencapturekit-integration.md](Docs/screencapturekit-integration.md)

---

## 2026.10.05 00:15 修正 Xcode 27 新編譯警告（捕捉與未使用的 throwing Task）

**類型**: 修復 · **檔案**: `liveAPP/liveAPPApp.swift`, `ReplyKIT/SampleHandler.swift`

### 問題 - Xcode 27 冒出兩類新警告

`#ImplicitStrongCapture`（liveAPPApp.swift 外層隱式強捕捉 self 與內層 `[weak self]` 不一致）與 `#NoUseUnstructuredThrowingTask`（SampleHandler 15 處 fire-and-forget 的 `Task {}` 含未處理 `try`，返回值被丟棄）。

### 根因 - 新版 Swift 對所有權與 throwing Task 更嚴格

外層閉包隱式強捕捉 self、內層顯式 weak，被判為所有權不明；`Task {}` 內有未處理的 `try await` 使其為 throwing，結果未使用時錯誤會被靜默吞掉。

### 修改 - 明確化捕捉與丟棄 Task

- liveAPPApp.swift：外層 `bufferQueue.async` 改 `{ [self] in }`（顯式強捕捉，行為不變），內層 workItem 維持 `[weak self]` 以避免成環。
- SampleHandler.swift：15 個 control handler（含 `try await requestSet`）的 `Task {` 改 `_ = Task {`，明確丟棄。

**相關文件**: [liveAPPApp.swift](liveAPP/liveAPPApp.swift), [SampleHandler.swift](ReplyKIT/SampleHandler.swift)

---

## 2026.10.05 修正 TTS 配置選檔流程並核對 TODO

**類型**: 修復 · **檔案**: `liveAPP/TTSSettingsView.swift`、`TODO.md`

### 修改 - 文件交付、背景讀取與頁面預覽

- 使用系統文件選擇器匯入副本，支援被標記為一般資料的 JSON，保留內容驗證與大小上限。
- 背景協調讀取檔案，移除 150 毫秒延遲與連續彈窗，改用頁面預覽及持續顯示的錯誤訊息。
- 新增選檔、取消、讀取與解析階段日誌；待 iOS 實機回歸驗證。
- TODO 修正已實作的動態島描述，將功能實作與實機／CI 驗收分開勾選。

**相關文件**: [TTS 配置分享](tts-filter-configuration.md)

---

## 2026.10.05 主頁重排與串流金鑰遮蔽

**類型**: 改進 · **檔案**: `liveAPP/ContentView.swift`、`liveAPP/Capture/CaptureCoordinator.swift`

### 修改 - 優先顯示擷取操作並依模式整理設定

- 主頁支援單欄／雙欄，進階控制預設收合；只錄製隱藏推流設定。
- 金鑰預設遮蔽，可手動顯示，離開表單或切至背景自動隱藏。
- 移除配置切換與關閉表單日誌中的金鑰，擷取與錄影狀態分行顯示。

**相關文件**: [主頁操作與金鑰顯示](home-layout.md)

---

## 2026.10.05 ScreenCaptureKit 本地錄影收尾加入方向轉正

**類型**: 修復 · **檔案**: `liveAPP/Capture/ScreenCaptureSource.swift`、`liveAPP/Capture/ScreenRecordingSession.swift`、`liveAPP/Capture/RecordingOrientationCorrector.swift`

### 問題 - 實測原生 MP4 畫面橫倒且未帶旋轉矩陣

本地錄製直接使用 SCRecordingOutput，未讀取影格方向，亦不經 RTMP Mixer，原本完成後立即開放分享。

### 修改 - 依 EXIF 方向收尾，保留原生錄製與失敗原檔

- 以輕量 screen output 收集 videoOrientation／PTS，僅保存有界方向事件，不保留影像 buffer。
- 固定方向使用 track transform 與 passthrough；方向變化時使用 video composition 分段轉正並重新編碼。
- 轉正期間維持 finishing；成功才取代原片，失敗保留原片並提示。加入背景工作到期取消與方向診斷。
- 新增時間軸及八方向矩陣測試；四項 Windows 核心測試通過，Apple SDK 與真實匯出待實機驗證。

**相關文件**: [ScreenCaptureKit 方向轉正](screencapturekit-integration.md)

---

## 2026.10.04 23:43 CI 補裝 Xcode 26+ 的 Metal Toolchain

**類型**: 優化 · **檔案**: `.github/workflows/unit-tests.yml`, `.github/workflows/main.yml`

### 問題 - CI 在 Xcode 27 下無法編譯 Metal

`liveAPP` 的單元測試與封存於 Xcode 27 環境失敗：`CompileMetalFile rotateNV12.metal` 報「The Metal Toolchain was not installed and could not compile the Metal source files」。

### 根因 - Xcode 26 起 Metal 編譯器改為需另下載的元件

Xcode 26 起把 Metal 編譯器（metalToolchain）從 Xcode 本體抽離成可選下載元件，未安裝即無法編譯任何 .metal。

### 修改 - workflow 於建置前安裝 metalToolchain

- unit-tests.yml 與 main.yml 在 Verify Xcode/iOS SDK 之後、所有 build 與 test 之前加入 `xcodebuild -downloadComponent metalToolchain`。
- 不加 sudo，以保留 DEVELOPER_DIR 讓指令選用正確的 Xcode 版本。

**相關文件**: [unit-tests.yml](.github/workflows/unit-tests.yml), [main.yml](.github/workflows/main.yml)

---

## 2026.10.04 CI 切換 Xcode 27 並強制檢查 iOS SDK

**類型**: 調整 · **檔案**: `.github/workflows/main.yml`、`.github/workflows/unit-tests.yml`

### 修改 - 確保 ScreenCaptureKit iOS 27 分支參與 CI

- 測試及封裝改用官方 `xcode-27` runner，固定 Xcode 27.0 Developer 目錄。
- 同時檢查 iPhoneOS／iPhoneSimulator SDK 為 27.x，不符即失敗，移除舊 SDK 僅提示後繼續的行為。
- 測試只選擇可用的 iOS 27 iPhone Simulator；沒有符合的 runtime 即失敗。
- runner 目前為公開預覽；本地格式驗證不代表 GitHub 上已編譯通過。

**相關文件**: [ScreenCaptureKit 接入](screencapturekit-integration.md) · [官方 runner 公告](https://github.blog/changelog/2026-09-10-xcode-27-runner-image-now-runs-on-macos-27/)

---

## 2026.10.04 新增關於與建置資訊及啟動來源日誌

**類型**: 新增 · **檔案**: `liveAPP/BuildInformation.swift`、`liveAPP/AboutBuildView.swift`、`Scripts/build_info.py`、`liveAPP.xcodeproj/project.pbxproj`、`.github/workflows/`

### 修改 - 以 Git 修訂與建置快照識別產物

- 設定頁新增關於與建置資訊，顯示 App／HaishinKit revision、未提交修改、建置時間、CI 編號與產物識別碼，提供完整資訊複製及分享。
- 每次主 App 建置產生 BuildInfo.json 並封裝入 bundle，啟動日誌使用同一份資料；不依賴專案版本號或 Build Version。
- 區分套件鎖定值與 checkout 核對結果；資訊缺失顯示未知，不把未知誤標為乾淨或已驗證。
- 統一 CI 套件 checkout 目錄，移除直接修改 HaishinKit 原始碼的 revision 注入方式。
- 新增 Python 產生器及 Swift 模型測試、中文欄位說明與封裝驗收待辦。

**相關文件**: [建置資訊說明](build-information.md)

---

## 2026.10.04 TTS 過濾配置匯入匯出與逐條啟用控制

**類型**: 新增 · **檔案**: `liveAPP/TTSSettingsView.swift`、`liveAPP/SpeechFilterConfiguration.swift`、`liveAPPTests/SpeechFilterConfigurationTests.swift`

### 修改 - 保存清單、規則狀態與明確替換順序

- 過濾設定頁新增 JSON 匯入、匯出及分享，檔案存入與 log.txt 相同的 Documents 目錄。
- 支援合併／取代與衝突預覽；套用前先自動備份，驗證或備份失敗不更動設定。
- 排除與替換規則新增逐條 enabled 開關，停用規則保留於清單、保存設定及匯出 JSON。
- 相容舊版字串／Dictionary 配置，缺少 enabled 預設啟用；新增替換順序保存與拖曳排序。
- 修正設定載入期間逐欄觸發儲存的問題，整批套用完成後才保存。
- 補上中文格式文件、可匯入範例與 11 項測試；Windows 核心測試通過，iOS 選檔及分享仍待實機驗收。

**相關文件**: [TTS 過濾配置](tts-filter-configuration.md) · [JSON 範例](examples/tts-filters.example.json)

---

## 2026.10.04 StreamMessage 新增單則訊息朗讀控制

**類型**: 新增 · **檔案**: `liveAPP/Socket.swift`、`liveAPPTests/StreamMessageTests.swift`

### 修改 - 可選 useTTS 欄位控制是否加入朗讀佇列

- `useTTS` 省略或為 null 時預設 true，維持舊訊息格式相容；false 只略過該則朗讀。
- 聊天顯示與觀眾資訊照常更新，不停止既有朗讀，不改動 App 的 TTS 總開關。
- 允許朗讀時仍沿用主要訊息與文字篩選；非布林值維持解碼失敗。
- 新增省略、null、true、false、非法型別及其他訊息欄位的解碼測試。

**相關文件**: [Socket 協定](socket-wire-protocol.md)

---

## 2026.10.04 接入 ScreenCaptureKit 雙來源、本地錄製與測試 CI

**類型**: 新增 · **檔案**: `liveAPP/Capture/`、`SharedCapture/`、`liveAPP/ContentView.swift`、`ReplyKIT/SampleHandler.swift`、`liveAPPTests/`、`.github/workflows/`

### 問題 - 新擷取來源需要保留舊版相容，並支援不推流的錄製測試

原有流程使用 ReplayKit 推流，缺少 ScreenCaptureKit 選項與獨立的本地錄製入口；單元測試亦需納入 CI 與發布前檢查。

### 修改 - 雙來源選擇、獨立輸出與持久錄影管理

- 保留預設 ReplayKit，新增 iOS 27 ScreenCaptureKit 測試選項；以 SDK 條件、弱連結與執行期可用性檢查保留舊系統支援。
- 提供只推流／只錄製／推流並錄製。只錄製不要求 RTMP 設定，也不建立推流 Mixer、編碼器或樣本消費佇列。
- 接入 SCRecordingOutput 的 MP4／H.264 錄製，顯示時間、大小及狀態；完成後可播放、分享／匯出、存入照片及刪除。
- 錄影與 JSON 紀錄存入持久目錄；只有完成回呼才能標為可用，失敗／收尾逾時／App 中斷的紀錄保留並標示。
- 推流與錄製分開處理失敗；網路重連耗盡時，有效錄製繼續，錄製失敗亦不連帶停止有效推流。
- 共用 Mixer 基本配置，加入跨程序擷取鎖、依位元組與停留時間限制的樣本佇列，以及來源／錄製診斷。
- PiP／TTS 的 Audio Session 設定在擷取期間受共同保護，避免覆蓋麥克風配置。
- 新增 PR／push／手動單元測試 workflow；發布前測試相同 commit，固定主 App scheme 與已鎖定的套件版本，保存測試結果及日誌。
- 補齊中文操作說明、API 回傳欄位與限制；未接入功能及實機驗收統一列入 TODO.md。

### 驗證 - 本地核心測試通過，Apple SDK 與實機驗收待完成

- Windows 執行 12 項擷取核心測試與 3 項檔案管理測試，合計 15 項通過；Swift 語法、plist 與差異格式檢查通過。
- Windows 測試排除 Apple UI／Photos 等整合，不能取代 Xcode 27 型別檢查、首次 CI 實跑或 iOS 27 實機驗收。
- 新來源尚未接入 GPU 畫布、浮水印、進階音訊處理、即時設定與 HEVC；本地錄影不包含下游 Mixer 音量或最終處理效果。

**相關文件**: [ScreenCaptureKit 使用方式與 API](screencapturekit-integration.md) · [集中待辦](../TODO.md)

---

## 2026.10.03 00:59 DeviceView 記憶體明細：footprint 拆解 internal/compressed/external

**類型**: 優化 · **檔案**: `liveAPP/OtherView.swift`

### 問題 - 只看總量無法判斷資源歸屬

設備信息頁只顯示 footprint 總量與 resident，容易把 external（約 53MB 映射）誤當成「可從 App 回收」而與 footprint 相減，得出「只用 2MB」的錯誤結論。

### 根因 - 未區分 footprint 內/外與可回收欄位

external 是檔案映射（框架／靜態庫 code），可被 evict 但不在 footprint 內；真正可回收應看 reusable／purgeable。

### 修改 - 新增 DeviceInfo.memoryBreakdown 與明細列

- 以單次 TASK_VM_INFO 取得 footprint/internal/compressed/external/resident/peak/reusable/purgeable 與 os_proc_available_memory。
- DeviceView 逐項顯示；external 標註「檔案映射、可 evict、非你的資料」，新增 reusable／purgeable 與「距 jetsam 上限」。
- 新增 PIPService.estimatedPixelBufferPoolMB（3×W×H×4）。

**相關文件**: [README.md](../README.md)

---

## 2026.10.03 00:51 log I/O 失敗新增帶外診斷通道（有界摘要 + Socket 群播）

**類型**: 新增 · **檔案**: `liveAPP/Socket.swift`

### 問題 - 寫入失敗被 try? 吞掉，現場無法排查

log 檔寫入失敗原本靜默，且不能寫回同一 log 管線（會造成回饋迴圈）。

### 根因 - 缺乏帶外且不依賴檔案的診斷通道

失敗訊號沒有可用的輸出：log 檔寫不進去、sendlog 會回流同管線。

### 修改 - 有界摘要以 diagnostic 訊息群播，OSLog 兜底

- 新增 socket type diagnostic（subsystem/source/count/lastError）；Server 收到只群播給其他連線，不寫檔。
- extension LogManager 與主 App AppLogPersister 寫入失敗時累積計數，每 60 秒最多送一則（SocketClient.sendPayload / SocketServer.broadcastDiagnostic）。
- 一律以 OSLog 記錄作底線；診斷不回流 log 管線。

**相關文件**: [socket-wire-protocol.md](socket-wire-protocol.md)

---

## 2026.10.03 00:45 log 檔 I/O 強化：write(contentsOf:) + early-log 批次 + 修重複累積

**類型**: 修復 · **檔案**: `ReplyKIT/Event.swift`

### 問題 - 寫入失敗會閃退、early-log 逐筆寫、group log 重複累積

FileHandle.write(_:) 失敗時 raise NSException 直接閃退；early-log 每筆一次 write 產生大量小 syscall；copyFromAppGroup 合併 group log.txt 後未清來源，每次啟動重複累積。

### 根因 - 使用非 throwing 的 write(_:) 且未批次、未清來源

write(_:) 為 ObjC 的 writeData:，錯誤以例外而非 Swift error 呈現；early-log 未進批次；合併後未截斷 group 檔。

### 修改 - 改 throwing API、批次化 early-log、合併後截斷

- 全部 log 檔寫入改 `try handle.write(contentsOf:)` 並經 `safeWrite` 包裝（ReplyKIT/Event.swift、liveAPP/liveAPPApp.swift）。
- early-log 改累積緩衝，滿 50 筆或 1 秒寫一次；forceFlush 收尾補送。
- copyFromAppGroup 合併 group log.txt 後 truncate 來源，修重複累積。

**相關文件**: [log-system-improvements.md](log-system-improvements.md)

---

## 2026.10.02 07:30 DeviceView 記憶體改以 phys_footprint 判斷

**類型**: 優化 · **檔案**: `liveAPP/OtherView.swift`

### 問題 - 記憶體讀數用 resident_size 導致誤判

DeviceView 顯示的「App 使用中」偏高（83-100MB），容易被當成異常佔用。

### 根因 - resident_size 含可回收映射頁

DeviceInfo 用 MACH_TASK_BASIC_INFO.resident_size，會把執行檔/框架（含靜態連結的媒體庫）可回收檔案映射頁算進去，並非 jetsam 採計值。

### 修改 - 改以 phys_footprint 為主、resident 降為對照

- 新增 DeviceInfo.appFootprintMB（TASK_VM_INFO.phys_footprint），原 appMemoryMB 保留為 resident 對照。
- DeviceView 主數字改顯示「App 實際佔用」(footprint)，resident 降為次要 caption 並加說明；折線圖改畫 footprint。
- StreamActivityManager 的 memoryUsage 與 log 也改用 appFootprintMB。

**相關文件**: [OtherView.swift](liveAPP/OtherView.swift)

---

## 2026.09.30 14:38 影像管線診斷 API 使用說明

**類型**: 新增 · **檔案**: `ReplyKIT/SampleHandler.swift`

### 修改 - 調整底層日誌回報 現在會回傳必要日誌

- 主App轉送需要保留 event.always 事件 此為底層必要日誌 重要診斷用日誌事件
- RTMPStream.videoPipelineSnapshot() -> VideoPipelineSnapshot 是 RTMP 推流的統一唯讀入口，包含原始影像佇列、編碼事件、RTMP 出站事件及背壓計數。此方法為 public nonisolated，不需要 await，不等待 RTMP／Mixer actor；內部仍會短暫取得統計鎖，並非完全無鎖。
- 僅使用 Mixer 時，可呼叫 MediaMixer.videoPipelineSnapshot() -> VideoMixerSnapshot。
- 舊的文字方法 videoPipelineDiagnostics() 仍保留，但新介面應使用結構化資料。

**相關文件**: [影像管線診斷 API 使用說明](https://github.com/TwhomeGH/HaishinKitFixSwfit/blob/main/Docs/VIDEO_PIPELINE_API.md)

---

## 2026.09.29 23:56 修正 RTMP video composition time 在 A/V 補償下變成負值（無畫面）

**類型**: 修復 · **檔案**: `Package.resolved`

### 問題 - H.264 以 IPPP（has_b_frames == 0）輸出，CTS 本應為 0 實際是負數

串流在 wire 上每個 video frame 的 FLV composition time（CTS）都是 −134/−135ms， 但 H.264 以 IPPP（has_b_frames == 0）輸出，CTS 本應為 0

VLC/ffmpeg 持續噴 Invalid timestamps stream=1, pts=..., dts=...

在 mpegts.js 低延遲設定 （isLive + liveBufferLatencyChasing + enableStashBuffer:false）下

pts < dts 的 視訊樣本被全部丟棄 → MSE 無 buffer、readyState 卡在 HAVE_METADATA，連線活著卻 完全沒有畫面。

### 根因 - RTMPStream.append(_:)：#57 附近的 A/V 偏移自動補償只把 avOffsetCompensation 加進 DTS 時間軸

但 CTS 的「無 decodeTimeStamp」分支用未補償的 presentationTimeStamp

去減已補償的 videoTimestamp.updatedAt，得 CTS = PTS − (PTS + comp) = −comp

且補償在此公式下自我抵銷 （wire PTS = (PTS+comp) + (−comp) = PTS），呈現時間沒有真正位移

### 修改 - 把 CTS 的計算抽成純函式 RTMPVideoCompositionTime.offset(hasValidDecodeTimeStamp:presentationTime:decodeTime:ctsOffset:)

RTMPStream.append 與 CMSampleBuffer.getCompositionTime 都改用它。

契約是保證 ≥ 0： 無重排（無 decodeTimeStamp）一律回 0；有重排才回 PTS − DTS + ctsOffset（clamp 0）。

A/V 補償只作用在 wire DTS/PTS，不再混入 CTS。修正後補償也才真正讓 wire PTS = sourcePTS + comp 生效。

**相關文件**: [修正 RTMP video composition time 在 A/V 補償下變成負值（無畫面）](https://github.com/TwhomeGH/HaishinKitFixSwfit/blob/main/CHANGES.md#60-%E6%9B%B4%E6%96%B0%E9%81%8E%E6%99%82%E7%9A%84-outgoingstream-buffer-count-%E6%B8%AC%E8%A9%A6--srt-%E9%82%8A%E7%95%8C%E5%A4%BE%E9%99%90--ci-%E6%97%A5%E8%AA%8C-ansi)

---

## 2026.09.29 22:25 變更歷史紀錄支援時間欄位

**類型**: 優化 · **檔案**: `Scripts/change_log.py`

### 問題 - 標題只有日期無法分辨同一天的先後

同一天多筆紀錄無法分辨時間與先後，也看不出是中午或晚上。

### 根因 - 標題只寫到日期

DATE_RE 與 build_block 只處理 `YYYY.MM.DD`，新增時也未帶入時刻。

### 修改 - 標題加入 HH:MM 並預設帶入現在時刻

- GUI 新增「時間（可留空）」欄，開啟表單時自動帶入本機當下時間（順帶修正原本用 UTC 的日期）。
- build_block 新增 time_str，有值才輸出 `YYYY.MM.DD HH:MM`，留空維持僅日期。
- DATE_RE 時間改為可選，舊的純日期紀錄照常解析。
- 列表與 cmd_list 顯示日期＋時間；CLI add 新增 --time（預設現在）。
- 更新 ChangeHistory.md 範本為 `## YYYY.MM.DD HH:MM 一句話標題`。

**相關文件**: [change_log.py](Scripts/change_log.py)

---

## 2026.09.29 變更歷史 GUI 新增紀錄視窗誤觸關閉

**類型**: 修復 · **檔案**: `Scripts/change_log.py`

### 問題 - 點背景就關閉，已填內容遺失

在新增紀錄視窗點到背景遮罩即關閉，尚未送出就丟失剛填的內容。

### 根因 - 遮罩綁定了點擊關閉

modal 綁定 click 事件，事件 target 為 #modal（背景）時直接設 hidden=true。

### 修改 - 僅按取消才關閉

移除遮罩點擊關閉的處理，新增紀錄視窗只在按「取消」時關閉。

**相關文件**: [change_log.py](Scripts/change_log.py)

---

## 2026.09.29 變更歷史 GUI 新增紀錄支援多筆相關文件

**類型**: 優化 · **檔案**: `Scripts/change_log.py`

### 問題 - 相關文件欄位只能填一筆

多筆相關文件無法附加，只能手動改 markdown 或塞在同一行。

### 根因 - 表單與 build_block 都只接受單一字串

新增紀錄表單用單一 input 收集相關文件，build_block() 只接受單一字串並原樣輸出。

### 修改 - GUI 改為可動態增減的多筆文件列

- 新增 _norm_refs()，同時接受 list 與每行一筆的字串，多筆以 ` · ` 串接。
- CLI `add` 新增可重複的 `--ref` 參數。

**相關文件**: [change_log.py](Scripts/change_log.py)

---

## 2026.09.29 原始影像佇列的容量預算與診斷

**類型**: 修復

### 修改 - 運作方式

- Mixer 的輸入與輸出分支不再使用固定容納 30 幀的 AsyncStream 緩衝區。 OutgoingStream 的自動模式也不再將計算出的預估幀數限制為最多 30 幀。 每個佇列會依實際像素緩衝區的資料大小計算容量；若沒有影像緩衝區，則使用壓縮樣本的資料大小。保留近期影格時，會同時遵守以下限制：
- 以位元組計算的容量預算。
- 最長停留時間，預設為 100 毫秒。
- 若消費端正在等待影格，佇列會立即通知它。這裡沒有 30 FPS 的速率限制。 當輸入速度超過消化速度時，會先捨棄佇列中最舊的影格，再保留新影格。 單幀大小若超過容量預算，會拒絕收下，並計入 oversizedDrop。 調整預算時會立即裁減目前的佇列，不會替換消費端。 停留時間會在影格送入與取出時檢查，不會為每幀建立到期計時器。 若生產端與消費端都停止動作，已保留的資料仍受容量預算約束，直到下次操作或呼叫 finish 才會進一步清理。

**相關文件**: [原始影像佇列的容量預算與診斷](https://github.com/TwhomeGH/HaishinKitFixSwfit/blob/main/Docs/VIDEO_QUEUE_DIAGNOSTICS.md)

---

## 2026.09.29 PiP 保活模式渲染效能改進

**類型**: 修復 · **檔案**: `liveAPP/PIPService.swift`

### 修改 - 發現與修正

- 保活目標為 0.2 FPS，但排程以 `1 / max(currentFPS, 1)` 計算，實際至少每秒喚醒一次。現在使用完整低幀率值，無覆蓋層時每 5 秒更新一次時間畫面。
- 遞迴 `asyncAfter` 沒有取消控制代次；停止後立即重啟會讓舊 callback 通過共用布林檢查，可能增加渲染迴圈。現在取消待執行工作並使舊代次失效，在主執行緒進入及離開渲染時都確認代次。
- `rescheduleRenderTimer` 原本是空函式。現在真正提前下一次更新，重複事件不會持續推遲畫面更新。
- 聊天、觀眾數及一般版面更新不再提升純保活畫面的幀率。保活模式原本不顯示聊天，現在也直接跳過聊天加入流程。
- 贊助覆蓋層顯示期間維持 6 FPS 以支援翻頁與淡出；結束時立即補畫保活畫面，再回到 0.2 FPS。
- 原本每次成功重繪都刷新活動時間，連時鐘重繪也會阻止聊天模式降頻。現在只用內容／動畫活動更新活動時間。
- 停止時清除快取像素緩衝；舊工作階段的 attach、啟動與停止回呼不會干擾新工作階段。
- 第一幀立即送出，不需等 5 秒才嘗試啟動 PiP。

---

## 2026.09.29 RTMP／H.264 解碼邊界恢復（更新 HaishinKitFixSwfit 依賴）

**類型**: 修復 · **檔案**: `Package.resolved`, `liveAPP.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

### 問題 - 已編碼封包丟失後仍繼續輸出、舊發布工作跨重連、未確認真正輸出的關鍵幀

已編碼資料遺失後串流仍持續輸出，舊的 publish 工作跨重連仍可能寫入新連線，且「要求關鍵幀」不代表 VT 已真正輸出；回放切回直播時非 IDR 影格先於直播 SPS/PPS 出現，造成大量語法解碼錯誤。

### 根因 - 輸出佇列與發布工作缺少世代隔離，關鍵幀未以實際輸出確認

有界輸出佇列滿載或 consumer 結束時只丟單一訊息而非整批作廢，失去連續性後仍續送；publish task／stream／connection 輸出之間沒有世代檢查，跨 actor hop 後未再驗證；VT session 未區分「已要求」與「已確認輸出」，非同步失敗被忽略。

### 修改 - 更新 HaishinKitFixSwfit 至含解碼邊界恢復的修訂

- 依賴修訂 `872d6fe` → `e842cbd`（`Package.resolved` 與 Xcode workspace 版本同步更新）
- 輸出順序不變式：先參數集、再關鍵幀、再依賴影格；新發布／編碼器重啟／格式改變時等待 sync sample，未等到不送 P 幀；每個 sync sample 前重送 sequence header（週期性重送用 type-1／零 delta，不改媒體時間軸）
- 丟失已編碼資料即失去連續性：stream／connection 有界輸出佇列遇滿載或 consumer 結束整批作廢，socket 容量保護改為關閉傳輸，改由既有斷線重連恢復
- 舊工作不得進新連線／新編碼器：publish task、stream 輸出與 connection 輸出加世代檢查，跨 actor hop 後於 connection 再次驗證
- VT 輸出改用獨立、有鎖的狀態：只有合法、ready、sync 的 callback 被 continuation 接受才算成功；丟幀或拒收繼續要求關鍵幀，非同步錯誤擋住後續輸出
- 正常停止與故障分開：正常拆除等待已接受尾幀排空，故障直接取消／作廢佇列；排空後再驗證世代，避免舊 teardown 清掉新 consumer

**相關文件**: [RTMP／H.264 解碼邊界恢復](https://github.com/TwhomeGH/HaishinKitFixSwfit/blob/main/Docs/RTMP_H264_RECOVERY.md#rtmph264-%E8%A7%A3%E7%A2%BC%E9%82%8A%E7%95%8C%E6%81%A2%E5%BE%A9)

---

## 2026.09.29 改進 Socket 心跳與連線日誌顯示

**類型**: 優化 · **檔案**: `liveAPP/Socket.swift`

### 問題 - 心跳日誌只顯示「收到Socket心跳維持連線」，看不出來自哪一組連線

同一則心跳訊息在不同連線都長得一樣，翻日誌時會誤以為服務端重複對同一個客戶端續命，實際上續的是不同連線者。

### 根因 - 主 App 每約 30 秒對所有連線廣播 `keepalive`，各用戶端分別回傳 `heartbeat`

每條連線都會回 `heartbeat` 並各自寫一筆日誌，但訊息不含連線識別，無法分辨是哪一條連線回覆。

### 修改 - 連線相關日誌統一帶上連線識別與遠端端點

- 新增 `connectionLogContext(_:)` 產生 `連線=ObjectIdentifier(...)｜遠端=位址:連接埠`
- 心跳日誌改為：`收到 Socket 心跳｜連線=…｜遠端=…`
- 新連線／ready／failed／cancelled／removed 等日誌也帶上同一組識別，便於對照同一條連線的生命週期

---

## 2026.09.17 連線診斷強化：connect/handshake 逾時、keepalive ping、onLog always 通道

**類型**: 修復

**修改**:

- OutgoingStream 執行緒安全 + keepalive 純型別化與測試
**相關文件**: [連線診斷強化：connect/handshake 逾時、keepalive ping、onLog always 通道](https://github.com/TwhomeGH/HaishinKitFixSwfit/blob/main/CHANGES.md#56-%E9%80%A3%E7%B7%9A%E8%A8%BA%E6%96%B7%E5%BC%B7%E5%8C%96connecthandshake-%E9%80%BE%E6%99%82keepalive-pingonlog-always-%E9%80%9A%E9%81%93)

---

## 2026.09.17 修復 liveAPP 背景執行緒寫 @Published 造成的 SwiftUI 死鎖

**類型**: 修復 · **檔案**: `liveAPP/ContentView.swift`, `liveAPP/Socket.swift`

**問題**: 主執行緒卡死，App 被 scene-update watchdog（`0x8BADF00D`）閃退。
**根因**: `SocketServer.handleDecodedPayload` 跑在背景 `SocketServerQueue`，卻直接改 `LiveVolumeModel` 的 `@Published`。SwiftUI 於是在背景啟動 AttributeGraph 更新並持有 movable lock，途中 UIKit（`UITab.setImage:` → diffable `applySnapshot`）同步等 main；主執行緒此時在 runloop flush 要拿同一把鎖，兩者互等即死鎖。
**修改**:

- `LiveVolumeModel` 標為 `@MainActor`
- `Socket.swift` 的 `audioLive` / `logbatch` 呼叫點包 `Task { @MainActor in ... }`
- CFNotification observer 亦改為 hop 回 main
**相關文件**: [design-issues.md](design-issues.md)

---

## 2026.09.17 強化崩潰診斷工具 crash_trace.py

**類型**: 優化 · **檔案**: `Docs/crash_trace.py`

**問題**: 拿 appex 的符號表去解主 App 的 crash，會用「最近符號」硬湊出錯誤函數名（例：把 `_main` 誤標成 `updateLogPageState`）；且 `bug_type 309` 一律標成 Stack Overflow。
**修改**:

- 原生解析 Mach-O nlist，符號來源以 crash 的 `slice_uuid` 驗證；`.txt` 檢查模組名，不符即拒絕符號化
- 依 `termination` 判定死因（`0x8BADF00D` → Watchdog Deadlock）
- 新增跨執行緒死鎖分析：找出持有 SwiftUI lock 的執行緒並印出 App 端堆疊
- 以 `swift-demangle` 還原 Swift 符號（未安裝則退回內建啟發式）
**相關文件**: [crash-tracing.md](crash-tracing.md)

---

## 2026.09.17 新增變更歷史工具 Scripts/change_log.py

**類型**: 新增 · **檔案**: `Scripts/change_log.py`, `Scripts/change_log.cmd`

**修改**:

- 本機網頁 GUI（零依賴，Python 內建 `http.server`）：清單、搜尋、就地編輯、刪除、新增表單
- 新增表單自動帶入 `git diff` 目前改動的檔案
- 深／淺色切換（記住選擇）、GitHub alert 樣式預覽
- CLI 子命令 `add` / `list` / `show`，供腳本化
**相關文件**: [github-alerts.md](github-alerts.md)

---

## 2026.09.17 Docs 重整：README 精簡、新增變更歷史與索引

**類型**: 重構 · **檔案**: `README.md`, `Docs/ChangeHistory.md`, `Docs/README.md`

**修改**:

- 主 `README.md` 只留常青內容（簡介／側載／功能／設定），修復紀錄移到 `Docs/ChangeHistory.md`（最新在上）
- 新增 `Docs/README.md` 分類索引
**相關文件**: [README.md](README.md)

---

## 2026.09.17 修正本機 GUI server 在 Windows 搶綁同一埠

**類型**: 修復 · **檔案**: `Scripts/change_log.py`

**問題**: 兩個 server 同時 LISTEN 同一埠，瀏覽器連到舊實例，改了程式卻看不到效果。
**根因**: Python `HTTPServer` 預設 `allow_reuse_address=1`，在 Windows 的 `SO_REUSEADDR` 允許第二個實例「搶綁」已被占用的埠。
**修改**:

- `allow_reuse_address=False`；埠被占用或落在 Windows 保留區段（如 8740-8839）時改用系統自動配置

---

## 2026.07.31 移除 MemoryWarning 監聽設計

移除記憶體壓力警告處理：[Docs/memory-warning-removal.md](memory-warning-removal.md)

- 不再於收到 memory warning 時清空 PiP buffer pool / Socket buffers
- 避免推流中管線重建與 log 遺失，防止推流中斷

---

## 2026.07.30 Metal Shader 性能優化

三項改進：[Docs/metal-shader-optimizations.md](metal-shader-optimizations.md)

1. 移除 `unsharpY` 死碼
2. Threadgroup 大小不再硬 cap 32（M 系列 GPU 使用 64-wide）
3. UV 16-tap bicubic → 4-tap bilinear 近似（texture sample 從 16 次降至 4 次）

---

## 2026.06.20 語音通話與直播共存

> [!WARNING]
> 該功能目前處於未知狀態 底層內部已自動註冊監聽 AVAudioSession 變化自動修正重啟音訊管線
>
> 該問題待確定實際上行為差異 仍有可能出現後續持續沒聲音的問題
> 請盡量避免啟用遊戲內語音通話 可能會有不穩定問題
>
> 此功能已被移除或取消
>

支援直播過程中同時進行語音通話（VoIP / LINE 通話 / 自建語聊），不中斷背景音樂播放。

### 啟用方式

```swift
// App 層（broadcastStarted / broadcastStarted）
RPScreenRecorder.shared().isMicrophoneEnabled = false  // 關閉 ReplayKit mic，避免雙重音源
try? await mediaMixer.setVoiceChatEnabled(true)
```

### 架構

| 元件 | 職責 |
| ------ | ------ |
| `AudioRouteManager` (iOS 限定) | 設定 AVAudioSession `.playAndRecord` + `.voiceChat` mode + `.mixWithOthers` + `.allowBluetooth` + `.defaultToSpeaker`；啟動 `AVAudioEngine` inputNode tap，將 mic PCM buffer 以 `Task { await mediaMixer.append(buffer, when:) }` 餵入現有音訊 pipeline |
| `MediaMixer.setVoiceChatEnabled(_:)` | 公開 API，內部呼叫 `AudioRouteManager.activate()` / `deactivate()` |
| `stopRunning()` | 自動停用 voice chat、釋放 engine、恢復 AVAudioSession `.playback` + `.mixWithOthers` |

### App 層需自行處理

1. **ReplayKit mic 雙重來源** — 啟用 voice chat 時，務必設 `RPScreenRecorder.shared().isMicrophoneEnabled = false`，只讓 ReplayKit 提供 `.audioApp`，mic 由 AVAudioEngine 負責
2. **通話下鏈（聽對方聲音）** — 由 app 自行管理（例如 `AVAudioEngine` mixer node 或系統 audio unit），本 SDK 僅處理 mic 上鏈
3. **Bluetooth 相容** — `.allowBluetooth` 確保藍牙耳機 mic 可用於通話

---

## 2026.06.19 重大修復：PTS 時間軸不一致導致部分平台無法推流

### 問題發現 - 影像 Pipeline 多個關鍵缺陷

在排查「部分 RTMP 平台一直推不上去」的問題時，發現影像 Pipeline 存在多個關鍵缺陷：

#### P0. 影音 PTS 使用不同 Timebase（最嚴重）

| 管線 | 使用的 PTS | 位置 |
| ------ | ----------- | ------ |
| 影片 | 虛擬牆鐘 `CACurrentMediaTime() - startTime` | `VideoProcess.swift` |
| 音訊 | ReplayKit 原始 `presentationTimeStamp` | `AudioProcess.swift` |

影片用 `CACurrentMediaTime()` 造假 PTS，音訊保留 ReplayKit 原始 PTS，兩者為**完全不同的 timebase**。嚴格 RTMP 伺服器/CDN 遇到 A/V PTS 在不同時間軸上跳動時，會直接斷流拒絕。

#### P0. 重連後 PTS 歸零

`VideoFrameProcessor` 的 `startTime` 在 init 時固定為 `CACurrentMediaTime()`。Broadcast Extension 重啟時（`broadcastFinished` → `broadcastStarted`），新的 Processor 產生新 `startTime`，PTS 從 0 重新開始。多數 RTMP 伺服器要求 PTS 嚴格單調遞增，歸零 = reject。

#### P0. 寫死 60fps Frame Duration

```swift
let cfduration = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
```

無論實際幀率多少，duration 始終為 1/60s。VFR（可變幀率）場景下送出錯誤的時間資訊。

#### P1. 無 Backpressure 控制

每幀以 `Task { }` 非同步 dispatch，GPU Rotator 處理不及時 frame 無限積壓，增加記憶體壓力與延遲。

#### P1. 多次重複 videoSettings 套用

`broadcastStarted` 中 `configureVideo_init()` → `configureVideo(sampleBuffer)` → publish 前又手動設一次，總共三次 `setVideoSettings()`，每次可能觸發 encoder 重建造成串流中斷。

#### P2. allowFrameReordering = false

限制編碼器不允許 B-frame，對部分伺服器反而有相容性問題。

#### P2. frameInterval 未設定

`VideoCodecSettings.frameInterval` 預設 0.0（自動），但 `expectedFrameRate` 已設 60fps，應明確設定 `frameInterval = 1/60`。

### 修正內容

#### VideoProcess.swift

| 修改 | 說明 |
| ------ | ------ |
| 移除 `startTime` | 不再使用牆鐘造假 PTS |
| 改用 `oringinaltime.presentationTimeStamp` | 與音訊使用同一 ReplayKit timebase |
| 改用 `oringinaltime.duration`（有效時） | 寫死 60fps → 真實 frame duration |
| 加入 inflight counter（上限 4） | 超過即 drop frame，防止 GPU 積壓 |

#### SampleHandler.swift

| 修改 | 說明 |
| ------ | ------ |
| `allowFrameReordering = true` | 允許 B-frame，與主流伺服器相容 |
| 移除 publish 前重複的 `setVideoSettings()` | 避免 encoder 反覆重建 |

---

## 2026.06.19 底層 HaishinKit 修復（RTMP 協定層）

在持續追蹤「部分平台推不上去」的問題時，往下排查到依賴的 HaishinKit fork 底層，發現兩個 Critical bug：

### 🔴 C1. Chunk `.two` Header 寫入範圍錯誤

**檔案**: `RTMPHaishinKit/Sources/RTMP/RTMPChunk.swift:305`

```swift
// ❌ ClosedRange：4 bytes 範圍但只寫入 3 bytes，第 4 byte 保留舊資料
data.replaceSubrange(position...position + 3, with: message.timestamp.bigEndian.data[1...3])
// ✅ Half-open range：精準 3 bytes
data.replaceSubrange(position..<position + 3, with: message.timestamp.bigEndian.data[1...3])
```

`.zero`（line 289）和 `.one`（line 298）正確使用 `..<` half-open range，唯獨 `.two` 誤用 `...` ClosedRange。導致第一個 `.two` chunk 送出後，下一個 chunk 的 basic header 被污染，串流資料從該點開始損毀。

**影響**: 對 RTMP 協定實作嚴謹的伺服器（如部分 CDN、Wowza、自研 server）在此刻斷流。

### 🔴 C2. E-RTMP（Enhanced RTMP）參數預設送出

**檔案**: `RTMPHaishinKit/Sources/RTMP/RTMPConnection.swift:261-263`

```swift
// ❌ 預設送出 fourCcList / videoFourCcInfoMap / audioFourCcInfoMap
fourCcList: [String]? = RTMPConnection.supportedFourCcList,
videoFourCcInfoMap: AMFObject? = RTMPConnection.supportedVideoFourCcInfoMap,
audioFourCcInfoMap: AMFObject? = RTMPConnection.supportedAudioFourCcInfoMap,
```

建制 `RTMPConnection()` 時這三個參數預設為非 nil，connect command 中會夾帶 `"capsEx"`、`"fourCcList"` 等 Enhanced RTMP 欄位。不支援 E-RTMP 的伺服器收到未知欄位時可能直接拒絕連線。

**修正**: 預設值改為 `nil`，只有呼叫端明確傳入時才送。

### 其他一併發現的問題

| 問題 | 位置 | 嚴重性 | 說明 |
| ------ | ------ | -------- | ------ |
| Timestamp 嚴格小於（`<`）而非小於等於 | `RTMPTimestamp.swift:21` | 🟡 | 重複 PTS 會 throw → frame 被靜默丟棄 |
| DTS 優先於 PTS 作為 RTMP timestamp | `RTMPStream.swift:764` | 🟡 | B-frame 場景送出錯誤的 presentation time |
| CTS 任意加 66ms offset | `RTMPMessage.swift:465` | 🟡 | A/V 不同步約 2 frames |
| Handshake C1 timestamp 永遠送 0 | `RTMPHandshake.swift:23` | 🟡 | 部分伺服器驗證此欄位 |
| `setVideoInputBufferCounts` 僅為 stored property setter | `StreamConvertible.swift:82-84` | 🟡 | **確認**：只在 publish() 前有效，runtime 無效 |
| 無 send buffer limit | `RTMPSocket.swift:86-112` | 🟡 | 慢網環境記憶體無限增長 |
| No keep-alive/ping | `RTMPConnection.swift` | 🟢 | 部分負載均衡器逾時斷連 |

---

## 最新重寫更新說明

本次針對 `ReplyKIT/rotateNV12.metal` 內的 `rotateNV12_bilinear` 與 `rotateNV12_bicubic` 重新整理了畫面旋轉與縮放對齊邏輯。

主要修正內容如下：

- 將輸出座標回推來源座標的流程改為統一使用中心點計算，避免旋轉時以左上角為基準造成畫面偏移
- 修正 4:3 畫面在 16:9 輸出下進行等比例適應時的對齊問題，例如 `1920x1334 -> 1920x1080` 會正確置中並保留左右黑邊
- 修正 `90` / `270` 度旋轉在目前畫面座標系下上下顛倒的問題
- 讓 `bicubic` 的 Y 平面取樣改回正確的 pixel-space 座標，避免取樣位置錯誤
- 調整 NV12 的 UV plane 寫入方式，改為每個 2x2 區塊只寫一次，避免多個 thread 同時寫入同一個 UV pixel 導致色度對齊不穩

這次重寫的重點是讓 GPU 旋轉後的輸出在不同長寬比、不同方向下都能維持正確的置中、縮放與色度對齊。
[版本標記說明 Version Note](development/version.md) · [本地建置工作流程 Build Workflow](workflow.md)

---

## LogView 頁面切換卡死修復 + 設備信息頁增強

### 問題 - LogView 切走仍在背景處理 log

切換到「日誌」或「音量」頁面再切走時，LogView 的 Coordinator 仍持續在背景處理 log 訊息：

- `appendWorkItem` 持續排入 main queue
- `shouldAutoScroll` 永不關閉（無 `onDisappear`）
- 大量 UITextView 操作佔用主執行緒，造成 App 卡死

### 修改 - 補 onDisappear 停止背景處理

#### LogView（`ContentView.swift`）

- 補上 `.onDisappear` → 設 `isVisible = false`、`shouldAutoScroll = false`、取消 pending work item
- `appendMessages()` 開頭檢查 `isVisible`，不在背景時直接 return
- 新增 `cancelPendingWork()` 方法清除排隊訊息

#### 設備信息頁（`OtherView.swift`）

重新設計 `DeviceView`，加入即時圖表與更多系統資訊：

| 項目 | 內容 |
| ------ | ------ |
| CPU 折線圖 | App CPU 使用率歷史 60 秒，搭配 SystemCPU 系統/用戶/閒置率 |
| RAM 折線圖 | App 記憶體用量歷史 60 秒 |
| 儲存空間 | 總容量 / 已使用 / 可用 GB |
| 網路介面 | WiFi / Cellular / No Connection |
| 系統資訊 | iOS 版本、開機時間、電量、電池狀態 |
| GPU | Metal 裝置名稱 |

---

## 統一 videoSettings 套用流程 + 移除 bitrate 雙路徑

### 問題 - configureVideo_init 設定不完整

1. **configureVideo_init() 設定不完整** — 只設了 videoSize + 寫死 `High_AutoLevel`，profileLevel/bitRateMode/keyFrameInterval 都沒設。第一次 frame 到來時 `configureVideo(_:)` 才補齊，但 publish 早已送出 metadata 不正確。
2. **attemptReconnect() 完全沒套 videoSettings** — 新建 `RTMPStream` 後直接 publish，encoder 用 HaishinKit 預設（854x480, profile Auto）。
3. **configureVideo(_:) 內重複 100+ 行** — profileLevel switch / bitRateMode / keyFrameInterval / allowFrameReordering 等邏輯跟 `configureVideo_init()` 重複。
4. **Bitrate 有兩條獨立路徑** — Darwin notification `bitRateChange` 更新 strategy max，Socket `applyRTMP` 直接設 encoder bitrate，兩者不同步。

### 修改 - 抽出 applyAllVideoSettings 統一

#### 新增共享函式

`applyAllVideoSettings(width:height:stream:setSize:)` — 一次套用所有設定：

- profileLevel（根據使用者選擇的 h264level + 解析度計算）
- scalingMode
- videoSize（可選，由 setSize 控制）
- expectedFrameRate
- bitRateMode（ABR / CBR / VBR）
- maxKeyFrameIntervalDuration
- allowFrameReordering
- isLowLatencyRateControlEnabled
- bitRate
- streamStataus.mamimumVideoBitRate (strategy max)

#### 三個呼叫點

| 呼叫點 | 原本行為 | 現在 |
| -------- | ---------- | ------ |
| `configureVideo_init()` | 只設 videoSize + 寫死 AutoHigh | 呼叫 `applyAllVideoSettings`，完整套用 |
| `attemptReconnect()` | 完全沒設任何 videoSettings | 先 `applyAllVideoSettings(stream: newStream)` 再 publish |
| `configureVideo(_:)` | 內聯 100+ 行重複邏輯 | 呼叫 `applyAllVideoSettings(setSize: false)` + 自己處理 orientation |

#### Bitrate 統一

- 移除 `bitrate` property + didSet
- 移除 `bitRateChange` Darwin notification handler
- `Eventlisten.swift` 移除 "bitRateChange" 註冊
- `applyAllVideoSettings()` 同時設 `videoSettings.bitRate` + `streamStataus?.updateVideoBitRate(to:)`

現在 bitrate 只有 socket 一條路：`GetRTMPConfig` → `applyRTMP` → `updateState` → `applyAllVideoSettings`，encoder 與 strategy max 在同一個點更新。

#### stateQueue 移除

- `Event.swift` 移除 `stateQueue.sync`（writes 有鎖 reads 沒鎖，等於白加，還可能 deadlock）

---

## Metal Shader 品質改造：float 精度 bicubic + unsharpen mask 後處理

### 問題 - 大動態畫面邊緣模糊、細節丟失

大動態畫面（快速運鏡、激烈運動）時，影像邊緣模糊、細節丟失。主要原因有二：

1. **Bicubic 插值使用 `half` 精度** — Catmull-Rom 三次係數在 `half`（10-bit 尾數）下運算會產生約 0.25 grey level 的捨入誤差，尤其在係數累加（~0.01~2.0 動態範圍）時誤差更明顯
2. **Interpolation 本身是平滑濾波** — 無論 bilinear 或 bicubic，旋轉+縮放後高頻細節會被自然衰減，缺少細節增強機制

### 修改 - bicubic/unsharp 改 float 精度

#### `rotateNV12.metal`

**Bicubic 全精度化：**

| 函數 | 修改前 | 修改後 |
| ------ | -------- | -------- |
| `catmullRom1D` | `half4` → `half` | `float4` → `float` |
| `catmullRom1D_uv` | `half2` → `half` | `float2` → `float` |
| `bicubicSampleY_16tap` | `half4 rows[4]`，`half4 col` | `float4 rows[4]`，`float4 col`，`float(tex.sample(...))` |
| `bicubicSampleUV_16tap` | `half2 rows[4]`，`half2 col[4]` | `float2 rows[4]`，`float2 col[4]`，`float2(tex.sample(...))` |

Texture read 維持 `half`（`r8Unorm` / `rg8Unorm` 本身就是 8-bit），但在進入算術運算前立即提升為 `float`，避免 interpolation 權重的累加誤差。

**新增 `unsharpY` kernel：**

```metal
kernel void unsharpY(
    texture2d<half, access::sample> srcY,   // 旋轉後的 Y
    texture2d<half, access::write>  dstY,   // sharpen 後的 Y
    constant float& amount,                 // 強度（0.0 ~ 0.5）
    uint2 gid)
```

演算法：

1. 3×3 Gaussian blur（未歸一化權重：中心 4、鄰邊 2、對角 1，總和 16）
2. `sharpened = center + amount × (center − blurred)`
3. Clamp 到 [0.0, 1.0] 後寫回

使用 `coord::pixel` 模式的 nearest sampler，避免多餘的正規化計算。

#### `GPUVideoRotator.swift`

- 新增 `sharpenPipeline: MTLComputePipelineState?` — `buildComputePipeline()` 中新增 Pipeline C
- 新增 `tempYTexture: MTLTexture?` — 避免同一個 command buffer 內讀寫衝突（rotation 寫 tempY → sharpen 讀 tempY 寫 dstY）
- `ensureMetalResources()` 的 guard 納入 `sharpenPipeline == nil` 檢查
- `cleanupResources()` 一併清理 sharpenPipeline + tempYTexture
- `renderPlaneYUV()` 內部根據品質模式決定 sharpen 強度

### 品質模式疊加

| 模式 | Interpolation | Unsharp | 行為 |
| ------ | ------------- | --------- | ------ |
| `.live`（預設） | Bilinear | 0.15（輕度） | 低運算成本 + 基本細節補救 |
| `.quality`（Bicubic） | Bicubic（float） | 0.25（中度） | 高精度插值 + 顯著細節增強 |

### 效果 - float bicubic 消除捨入誤差

- **float 精度的 bicubic**：消除係數捨入誤差，在平滑漸層區域有更乾淨的 interpolation
- **Unsharpen mask**：在不改變 interpolation 方式的前提下，主動恢復被平滑的高頻邊緣
- **兩 pass 獨立**：`unsharpY` 與 rotation kernel 分屬不同 compute encoder，中間依賴 implicit barrier 確保資料正確性

---

## 修復 Socket 連線穩定性與首次推流解析度錯誤

### 問題描述 - 首次推流解析度錯誤 + Socket 不穩

1. **首次推流解析度錯誤**：第一次推流時常變成 854x480，而非用戶指定的解析度（如 1920x1080）
2. **Socket 死連接/殘留 Listener**：切換直播後舊連線未完全清理，導致新連線無法正常通訊

### 根因分析 - 854x480 錯誤解析度根因

**854x480 錯誤解析度：**

- 當 `socket` 請求回傳的 `ODWidth`/`ODHeight` 與 `ADWidth`/`ADHeight` 皆為 0 時，`configureVideo` 跳過解析度設定，HaishinKit 使用預設 854x480
- `SocketClient` 在連線尚未 `.ready` 時就發送 batch 請求，導致首次推流常 timeout 或拿到空配置

**Socket 死連接：**

- `SocketServer.isRunning` computed property 有副作用（直接 `listener.cancel()`、`listener = nil`），造成多次存取時的 race condition
- `receive()` callback 在 `removeConnection` 後仍可能執行，訪問已釋放的 buffer
- `SocketClient.setupConnection()` 直接覆蓋 `connection` 而不清理舊連線，舊連線的 receive 迴圈仍在背景運作
- `rtmpBatchContinuation` 等 continuation 在連線關閉時未清理，造成記憶體洩漏

### 修改內容

#### 1. SocketClient（`ReplyKIT/Socket.swift`）

- **setupConnection()**：先 closeConnection 清理舊連線再建立新連線
- **waitForReady(timeout:)**：新增 async 方法，等待連線 `.ready` 後才發送請求（3s timeout）
- **closeConnection()**：同步清理所有 pending continuation（rtmp、log、batch、ContinuationStore），避免洩漏
- **\_requestRTMPKEYAndLog() / \_requestRTMPKEY() / \_requestLogConfig()**：都先 await waitForReady() 再發送
- **ContinuationStore**：新增 cancelAll() 清理所有殘留的 continuation

#### 2. SocketServer（`liveAPP/Socket.swift`）

- **isRunning**：改為純 computed property，移除所有副作用
- **cleanupStaleListener()**：獨立方法處理 failed/cancelled listener 的清理
- **receive(from:)**：增加多層 `guard connections[id] != nil` 檢查，防止 callback 在連線移除後繼續處理
- **start()**：先調用 cleanupStaleListener() 再檢查狀態

#### 3. SampleHandler（`ReplyKIT/SampleHandler.swift`）

- **configureVideo_init()**：encoder 優先使用 OD，沒有 OD 才使用 AD；socket bridge 模式不使用 App Group fallback
- **configureVideo()**：相同尺寸來源規則
- **broadcastStarted publish 前**：最終 videoSize 檢查也遵守 OD 優先、socket 不 fallback 到 App Group 的規則

---

## 修復 GPU 旋轉初始化失敗造成畫面無法送出 (0x0)

### 問題描述 - 推流輸出 0x0，編碼器無幀

推流畫面完全沒送出去，輸出為 0x0，編碼器無幀可編。

### 根因

`GPUVideoRotator.ensureMetalResources()` 在 `hasMetalResources` 設為 `true` 之後才進行實際資源初始化（textureCache、computePipeline）。若初始化失敗（如 GPU 暫時忙碌、shader 編譯失敗），函數回傳 `false` 但 flag 已永久鎖定為 `true`。後續所有幀的呼叫直接跳過初始化，使用 nil 資源，全部靜默丟棄。

### 修復 - hasMetalResources 初始化成功才設 true

- **`hasMetalResources`**：改為在所有資源初始化成功後才設為 `true`
- **getReusableOutput 前**：加入 `dstW > 0 && dstH > 0` 保護，防止無效維度進入 GPU 管線

---

## 修復 Rotate 事件處理器維度條件錯誤

### 問題 - OD/AD 維度用 || 誤判有效

`SampleHandler.swift:540,543` 使用 `||`（OR）而非 `&&`（AND）判斷 OD/AD 維度有效性。例如 `ODWidth=1920` 但 `ODHeight=0` 時，仍會設定 `NewVW=1920, NewVH=0`，造成 `videoSize` 單軸為 0。

### 修復 - 改用 && 判斷寬高有效

改為 `&&`，確保寬高同時有效才套用。

---

## 修復 broadcastStarted 維度混合問題

### 問題 - broadcastStarted OD/AD 寬高獨立檢查

`broadcastStarted` 中 ODWidth 與 ODHeight 獨立檢查（`ODWidth > 0 ? ODWidth : ADWidth`），可導致 OD Width 與 AD Height 被混合使用。

### 修復 - 成對檢查 OD/AD 維度

改為成對檢查（OD 兩者 > 0 或 AD 兩者 > 0），維持維度一致性。

---

## 修復 OutW/OutH 分開觸發造成 videoSize 維度不一致

### 問題 - OutW/OutH 分開觸發造成維度不一致

`OutW` 與 `OutH` 是兩個獨立的 Darwin Notification，App 端先發 OutW、再發 OutH。
Extension 端原本的處理方式：

- **OutW** 只改 `videoSize.width`
- **OutH** 只改 `videoSize.height`

這導致 OutW 處理完、OutH 尚未到達的時間窗口中，`videoSize` 為 **(新寬度, 舊高度)** 的錯誤組合。
若編碼器在此時讀取，會得到錯誤解析度（如 854x480 或 0x0）。

### 修復 - OutW/OutH 一次原子套用

`OutW`/`OutH` 現在會一次讀齊完整尺寸並原子套用，encoder 使用最終畫布尺寸，GPU rotator 使用中間處理尺寸。
詳細 AD/OD 設計與 preset 對照見 [Docs/video-dimensions.md](video-dimensions.md)。

---

## 停用 AdaptiveVideoBufferManager

### 原因

經查閱 HaishinKit 原始碼，`setVideoInputBufferCounts` 僅為 **stored property setter**，
其設定的值只在 `videoInputStream` computed property 被存取時讀取一次。
而 `videoInputStream` 的 `for await` loop 在 stream 啟動時就已固定，**runtime 期間呼叫完全無效**。

### 修改 - 移除 monitorFPSAndAdjust 呼叫

- 移除每幀對 `AdaptiveVideoBufferManager.monitorFPSAndAdjust` 的呼叫
- 保留初始化時從 `RPConfig.shared.state.BufferCount` 設定一次的邏輯（`configureVideo_init` 與 reconnect 處）

---

## 修復 Metal 管線中途失敗無自動重建

### 問題 - Metal 管線中途失敗無自動重建

`GPUVideoRotator` 的 `hasMetalResources` 一旦設為 `true` 就永久鎖定，
`ensureMetalResources()` 永遠直接 return，不會重試初始化。
若 GPU 中途重置或記憶體不足造成 texture/command buffer 建立失敗，
所有後續幀靜默丟棄，沒有任何復原路徑。

### 修復 - 加入失敗計數器自動重建

`GPUVideoRotator.swift` 加入 `consecutiveMetalFailures` 計數器：

- `getReusableOutput` 失敗 → 計數 +1
- `makeTexture` / `makeCommandBuffer` 失敗 → 計數 +1
- 幀成功送出 → 計數歸零
- 連續失敗達 **5 次** → 自動呼叫 `cleanupResources()`，
  重置 `hasMetalResources`、textureCache、pipeline
- 下一幀的 `ensureMetalResources()` 會從頭重建整條 Metal 管線

---

## 新增可設定關鍵幀間隔（KeyFrameInterval）

### 問題 - maxKeyFrameIntervalDuration 鎖死

推流到 Restream 等平台時被拒，因為 `maxKeyFrameIntervalDuration` 原本鎖死在
位元率模式對應的固定值（ABR=3s, CBR=4s, VBR=2s），部分平台要求更嚴格的 GOP 規範。

### 修改 - Setting 新增關鍵幀間隔輸入

- `Setting.swift` 新增「關鍵幀間隔」文字輸入框（預設 2 秒）
- `SampleHandler.swift` 移除 per-mode 硬編碼，改為統一讀取 `RPConfig.shared.state.KeyFrameInterval`（支援 Socket 傳遞，側載用戶也可用）
- 值為 `0` 表示由編碼器自動決定（無最大間隔限制）

---

## 修復 h264ProfileLevel 在高解析度下回傳無效 Level

### 問題 - Baseline/Main 缺中高階 Level

`h264ProfileLevel` 中 Baseline 和 Main 的 switch 缺少中高階 Level 範圍。
對於 iPad 常見的 1920x1334 原始解析度（mbPerFrame≈10285），
兩者都跳進 `default` 回傳 `xxx_4_2`，但 Level 4.2 最大只支援 8704 mb/frame。

- **Baseline 4.2**：H.264 標準中 Baseline 最高只到 Level 4.1，回傳 4.2 是非法的
- **Main 4.2**：10285 > 8704，超出 Level 4.2 規格，VideoToolbox 可能拒絕或編碼異常

### 修復 - Baseline 改 AutoLevel

- **Baseline `default`** → 改為 `Baseline_AutoLevel`（讓編碼器自動選擇）
- **Main** → 補上 `8192..<8704`(4.2)、`8704..<36864`(5.0)、`>=36864`(5.1/5.2) 等完整範圍
- **High** → 維持不變（原本就有完整範圍）

---

## 改進音視頻管道處理

目前音頻帶降噪功能 可選使用Metal加速
當前設計 額外套用自動降級保護 如果GPU忙不過來會嘗試降級到CPU
如果到後面完全處理不過來 會嘗試原始音訊傳送
確保系統在某些異常負載下 能夠保持音訊正常

### 原始音訊管線效能優化 (2026/06)

當使用原始音訊模式（無降噪/回音消除/AGC）時，先前因以下問題導致音訊斷斷續續：

| 問題 | 修復 | 預期效果 |
| ------ | ------ | --------- |
| `amplifySIMD` 每次呼叫 heap alloc Float buffer（每秒近百次 malloc/free） | 改用預分配 `[Float]` buffer 重用 | 零 heap alloc，消除碎片化 |
| useOriginal 的增益可能誤改原始音訊格式 | `applyGain` 先檢查 ASBD，signed Int16 / Float32 PCM 且 gain > 1 時才原地增益 | 未支援 PCM 維持 passthrough，避免原音管線破壞音訊 |
| `retimeAudioBuffer` 每秒百次 shallow copy，但 99% 只用於 RMS（每秒才觸發一次） | 移入 `processRMS` 內部，只在真正需要時建立 | 每秒節省 ~99 次 CMSampleBuffer 物件建立 |
| 上層 drop/lock gate 疊在 `AudioProcessorActor` 外 | 移除重複 gate；`AudioPreProcessor.processLock` 也移除 | 減少熱路徑同步成本，避免把延遲放大成掉幀 |

### GPU 密集型遊戲導致直播掉幀（已知 iOS 系統限制）

> [!NOTE]
> 測試遊戲：第五人格（活動子頁面 / 內嵌小遊戲場景）

當 GPU 密集型遊戲開啟高負載子頁面時，直播幀數可能瞬崩至 2-10 fps，遊戲本身不受影響，關閉子頁面立刻恢復。這是 iOS 系統級 GPU 排程行為：**前景 App 的 GPU 優先權永遠高於 ReplayKit 廣播擴展**。

`videoInputFrames`（RTMP 吞吐量 log）是 ReplayKit 交給我們的原始幀數。若此值持續低於 20 且 video processor 無異常（`[VProc] active:true processing:false`），即為系統節流，非本專案 bug。GPU 旋轉降級到 CPU 或降低碼率都無法改善（瓶頸在擷取端螢幕合成器，不在後處理）。詳見 `Docs/replykit-core-fixes-summary.md` §9。

---

## 修復音訊 Metal/CPU 反覆切換與 iOS 26 Beta Crash

### 問題發現 - GPULatencyTracker 永久鎖定 GPU

#### 1. GPULatencyTracker 永久鎖定（永不恢復 Metal）

`AudioNoiseMetal.swift` 的 `GPULatencyTracker` 在判定 GPU 過載後 (`isOverloaded = true`)，`record()` 只在 Metal 路徑被呼叫。一旦切到 CPU fallback，歷史記錄凍結，`isOverloaded` 永遠回不來，**音訊永久鎖在 CPU 模式**。

#### 2. AudioPreProcessor.processMic force unwrap crash（iOS 26 Beta）

`AudioNoiseFix.swift:489` 的 `metalNS!` 與 `AudioNoiseMetal.swift` / `AudioNoiseFix.swift` 共 7 處 `baseAddress!` force unwrap，在 iOS 26 Beta 下 Swift runtime 觸發 `EXC_BREAKPOINT` / `SIGTRAP`。

Crash 路徑：`RPBroadcastSampleHandler _processPayloadWithAudioSample:` → Audio pipeline FFT 處理 → `baseAddress!` force unwrap of nil

#### 3. VideoProcess sampleBuffer 長期持有

`VideoFrameProcessor.process()` 的 `sampleBuffer` 被 Task closure strongly capture，直到 GPU rotation 完成才釋放。ReplayKit 的 buffer pool 因此被阻塞。

### 修改 - GPU 連續失敗冷卻與 CPU 降級

| 檔案 | 問題 | 修改 |
| ------ | ------ | ------ |
| `AudioNoiseMetal.swift:15-53` | `GPULatencyTracker` 永久鎖定 | 加入 3 秒冷卻機制：overload 後 CPU 模式 3 秒，期滿自動 reset 嘗試恢復 Metal |
| `AudioNoiseFix.swift:480-491` | `metalNS!` force unwrap | 重構為巢狀 `if let metalNS = metalNS`，消除 force unwrap |
| `AudioNoiseMetal.swift:204-268` | `baseAddress!` × 4 | 改為 `guard let` + graceful skip（不 crash，該 frame passthrough） |
| `AudioNoiseFix.swift:196-308` | `baseAddress!` × 3 | 同上 |
| `VideoProcess.swift:102-104` | sampleBuffer 被 Task capture | Task 前提取 `CVPixelBuffer`，使 CMSampleBuffer 即時回到 ReplayKit pool |
| `GPUVideoRotator.swift:502` | rotateAsync 需 CMSampleBuffer | 參數改為 `CVPixelBuffer`，與上述修改對應 |

---

#### 4. Metal 音訊與影片共用同一條 Command Queue 造成音訊撕裂

##### 問題 - 音訊與影片共用 Command Queue 造成撕裂

`MetalContext.shared.queue` 被 `AudioNoiseMetal`（音訊降噪）與 `GPUVideoRotator`（影片旋轉）共用。
影片渲染的 GPU command 塞在 queue 前端時，音訊的 noise suppression kernel 必須排隊等待，
導致 `runMetalKernelWithTimeout` 中的 `DispatchSemaphore.wait(timeout:)` 逾時或延遲，
音訊即時管線無法在 frame 週期內完成（512 samples @ 48kHz ≈ 10.67ms），
聽表現為音訊撕裂、爆音。

##### 修改 - 音訊改用獨立 Command Queue

`AudioNoiseMetal.swift:132-139` — 不再取用 `MetalContext.shared.queue`，改為獨立建立一條
`metalDevice.makeCommandQueue()`，音訊的 GPU 指令不再被影片工作阻塞。

| 改前 | 改後 |
| ------ | ------ |
| `metalQueue = ctx.queue`（與影片共用） | `metalQueue = metalDevice.makeCommandQueue()!`（專屬音訊） |

### 行為對比

| 情境 | 改前 | 改後 |
| ------ | ------ | ------ |
| GPU 短暫過載 >8ms | 永久鎖 CPU | CPU 3s → 自動重試 Metal |
| GPU 持續過載 | 永久鎖 CPU | 每 3s 嘗試一次 Metal，持續失敗則持續停在 CPU |
| `baseAddress` 為 nil | `EXC_BREAKPOINT` crash | 安全跳過該 frame 處理，音訊 passthrough |
| ReplayKit buffer pool | 被 Task 長時間佔用 | 提早回收，減少 buffer 競爭 |

### GPU 管線瘦身 (2026/07)

`GPUVideoRotator` 原先每幀執行 2 次 GPU dispatch（旋轉 + 始終開啟的 unsharpen mask 銳化），且初始化時編譯 3 條 shader pipeline。整理後僅編譯使用者選擇的 1 條 pipeline，移除多餘的 sharpen post-pass。每幀 GPU 從 2 dispatches → 1 dispatch，畫質不變。詳見 `Docs/replykit-core-fixes-summary.md` §12。

### GPU 管線逾時重建強化 (2026/07)

針對直播啟動或 GPU 短暫異常時 `MTLCommandBuffer.addCompletedHandler` 不回呼的情境，`GPUVideoRotator` 加入 command buffer 逾時保護：1.8 秒未完成即讓 `rotateAsync()` 回傳 `nil`，避免 `ProcessorActor` 永久卡在 `isProcessing = true`。同時 `VideoFrameProcessor` 加入 `processingGeneration`，watchdog 重建後舊任務若延遲返回，不會誤清新管線的處理狀態。

另外，watchdog 重建現在會先值捕獲舊 actor 再非同步 cleanup 舊 rotator，確保不是只把 `processorActor` 設成 `nil`。`renderPlaneYUV()` 也改為回傳成功/失敗，拿不到 compute pipeline 或 command encoder 時會立即回收 buffer 並累計 Metal failure，不再 commit 空 command buffer。詳見 `Docs/replykit-core-fixes-summary.md` §16。

---

## 修復 VFR 造成的 PTS 異常與畫面速率抖動

### 問題發現 - 直播約 54 分後畫面速率異常

在分析一段長時間直播錄影時，發現影片從約 **54分30秒** 後出現嚴重的畫面速率異常：

- **ffprobe 分析結果**：`r_frame_rate=60/1`（聲稱 60fps）但 `avg_frame_rate≈100`，metadata 與實際不符
- **封包結構**：約 **70% 的幀是「微幀」**（duration = 0.000011s，僅 1 個 PTS tick），穿插在正常 0.016-0.017s 幀之間
- **觸發點**：~54:30 處編碼器嚴重卡頓（幀間隔高達 1.4s ~ 9.9s），恢復後即進入缺陷模式

### 根因分析 - 音視頻管線三個設計缺陷

透過原始碼追溯，確認問題出在 **ReplyKIT 音視頻管線的三個設計缺陷**：

| 問題 | 位置 | 影響 |
| ------ | ------ | ------ |
| `allowFrameReordering=true` + VFR 輸入 | `SampleHandler.swift:2178` | VideoToolbox B-frame 重排序導致 PTS 損毀 |
| MediaMixer passthrough 無 CFR 轉換 | `SampleHandler.swift:1343` | VFR 原樣送入編碼器，不做 PTS 平滑 |
| `AdaptiveVideoBufferManager` 被註解 | `AdaptiveVideoBufferManager.swift` | 無動態 buffer 緩衝，過載時直接崩潰 |

**問題鏈**：

1. ReplayKit 本質是 **VFR**（畫面無變化就不送 buffer）
2. `MediaMixer` 設為 `passthrough`，不做任何 PTS 平滑
3. `allowFrameReordering=true` 讓 VideoToolbox 開啟 B-frame 重排序（`has_b_frames=15`）
4. 系統過載時 PTS 出現巨大間隔 → B-frame 重排序邏輯錯亂 → 輸出大量微幀
5. 編碼器恢復後從未修正，缺陷持續到結束

### 三層防禦改進

#### 1. 關閉 Frame Reordering

`SampleHandler.swift:2178` — 硬編碼為 `false`，並從配置項與 UI 完全移除：

```swift
videoSettings.allowFrameReordering = false
```

這阻止 VideoToolbox 做 B-frame 重排序，從根源避免 PTS 損毀。

#### 2. CFR 平滑（Constant Frame Rate）

`VideoProcess.swift` — 在 GPU 旋轉後、送入 MediaMixer 前，以 frameCount 產生恒定 PTS：

```swift
let correctedPTS = CMTime(value: frameCount, timescale: 60)
// ... CMSampleBufferCreateCopyWithNewTiming ...
frameCount += 1
```

無論 ReplayKit 以何種 VFR 送幀，編碼器永遠收到 0, 1/60s, 2/60s... 的恒定 PTS。

#### 3. 靜態 Buffer 設定（取代動態調整）

原 AdaptiveVideoBufferManager 提供的動態 buffer 管理已**停用**（經確認 `setVideoInputBufferCounts` 在 runtime 無效），
改為在初始化階段從 `RPConfig.shared.state.BufferCount` 設定一次：

- `configureVideo_init` 處設定初始值
- reconnect 建立新 stream 時重新設定

### 效果 - 三層防禦形成完整保護

這三層防禦形成完整保護：

- **第一層**：不允許 B-frame 重排序 → PTS 不會被編碼器亂序打亂
- **第二層**：CFR 強制修正 PTS → 無論輸入多亂，輸出永遠是 60fps 節奏
- **第三層**：靜態 buffer 管理 → 根據設備核心數與用戶設定選擇合理初始值

---

## 新增重連設計

當直播因網路問題 沒有連線成功 會最多嘗試重連 最多5次
也會顯示在子母窗口上 提示當前重連次數

### 修正 `0/5` 重連狀態誤判

`reconnectStatus` 的 `attempt = 0` 不視為真正斷線重連，只代表 RTMP 狀態機尚未進入有效重連次數，或正在回復正常。主 App 收到 `attempting 0` / `failed 0` 時會清空 PiP / Live Activity 的重連狀態，避免畫面殘留 `0/5` 並誤判為沒連上。

Broadcast Extension 端也避免在初始 `publish` 失敗時送出 `failed 0`；只有 HaishinKit reconnect callback 回報有效次數後，才會顯示重連提示。
主要是針對音畫時間軸校正

在最新版本目前加上音軌的PTS校正 雖然說音軌偏移照理說應該不會發生

但考量前幾個版本只對畫面做PTS校正 有概率在某些情況下可能出現異常

所以兩者皆補上了PTS修正

---

## 最新 PiP 背景存活與渲染效能優化

本次針對 PiP 子母畫面在背景被系統終止、動畫與渲染效能進行全面改善：

### 背景存活修復

- **PIPService**: 放寬 `attachToForegroundWindow` 綁定條件，接受任何已連接的 Scene
- **PIPService**: 新增 `handleMemoryWarning()`、background task 生命週期、app 前景/背景切換時自動重連 displayLayer
- **liveAPPApp.swift**: scenePhase `.background` 時啟動短 background window，並排程 BGTaskScheduler 機會型 socket refresh；BGTask 不再被視為常駐保活機制
- **Socket.swift**: 新增 `suspend()` / `resume()` / `releaseMemory()`，背景時釋放緩衝區、前景恢復運作

### 動畫迴圈重構

- 移除 `CADisplayLink`，改由 PIPService render timer 統一驅動，消除雙 loop 不同步
- 以 `tickAnimation()` 狀態機取代舊的 step 方法，動畫進行中持續回呼
- 穩定 FPS 策略：動畫中 24fps、有訊息/活動 8fps、閒置 1fps，取代舊的跳 60→衰減機制，消除 FPS 震盪並降低 CPU 壓力

### Render Pipeline 最佳化

- 跳過 `UIGraphicsImageRenderer` → `CGImage` → `CIImage` → `CIContext.render()` 的兩次 round-trip
- 改為 `CVPixelBufferPool` + 直接 `CGContext(data:)` 將 CALayer tree 渲染到 pixel buffer 記憶體
- 回全 CPU 渲染：移除不再使用的 GPU renderer、Metal-compatible PiP pool、Metal device、CIContext 等 dead code
- `CMVideoFormatDescription`、`CGColorSpace`、時間/觀眾/重連 SF Symbol 改為快取，不再每幀重建
- `AVSampleBufferDisplayLayer` 背壓時先跳過，不再先畫完整 frame 再丟棄
- 詳細紀錄見 `Docs/replykit-core-fixes-summary.md` §17

---

## 新增 TTS 佇列上限控制 (maxQueueSize)

### 問題 - TTS 佇列無上限

`AVSpeechSynthesizer` 無公開 API 查詢內部佇列深度，連續大量朗讀時佇列可能無限增長，
極端情況下導致記憶體壓力甚至崩潰。

### 修改 - TTS 佇列上限與清空選項

- `TTSService.swift`：新增 `maxQueueSize`（0=無限制/5/10/20/50）與 `queueOverflowAction`
- 透過 `AVSpeechSynthesizerDelegate`（`didFinish`/`didCancel`）維護 `pendingUtteranceCount`
- `stopSpeaking(at: .immediate)` 時手動重置計數為 0
- `speak()` 在佇列已滿時根據 `queueOverflowAction` 決定跳過新訊息或清空佇列
- `TTSSettingsView.swift`：設定頁面新增「佇列上限」Picker 與「佇列滿載」Picker
- 新增 `TTSQueueOverflowAction` 列舉 (skipNew / stopOld)

### 相關檔案

- `liveAPP/TTSService.swift`：佇列計數 + 上限控制 + delegate
- `liveAPP/TTSSettingsView.swift`：佇列設定 UI

---

## 修復 TTS 過濾器誤刪數字 + 新增純數字過濾選項

### 問題 - TTS 過濾器誤刪數字

`SpeechFilterManager.processMessage()` 在「移除表情符號」階段使用 `isEmoji` 過濾，
但 Swift 的 `UnicodeScalar.properties.isEmoji` 對數字 `0-9`、`#`、`*` 也回傳 `true`
（因為這些字元可以透過 Variant Selector-16 組合成 emoji keycap 序列，如 `#️⃣`、`0️⃣`），
導致朗讀時數字被誤刪。

### 修改 - 修正過濾器並新增純數字選項

#### `TTSSettingsView.swift - SpeechFilterManager`

| 變更 | 說明 |
| ------ | ------ |
| `isEmoji` → `isEmojiPresentation` | `isEmojiPresentation` 只對「預設顯示為 emoji」的字元回傳 true，數字、#、* 不再被誤刪 |
| 新增 `removePureNumbers` 屬性 | 可選是否移除純數字內容，使用正則 `(?<!\d)\d+(?!\d)` 確保只移除獨立數字，保留「第5名」這類混合內容 |
| 新增儲存/載入 | UserDefaults 序列化新增 `removePureNumbers` 欄位 |

#### UI 新增

TTS 過濾器設定頁面新增「移除純數字」Toggle 開關。

---

## 修復 PIP unsafeBitCast 潛在崩潰

### 問題 - PIP unsafeBitCast 潛在崩潰

`PIPService.swift:createSampleBuffer()` 中 `CFArrayGetValueAtIndex(attachments, 0)` 的結果
直接傳入 `unsafeBitCast`，若陣列為空則回傳 nil，`unsafeBitCast(nil, to:)` 會觸發 crash。

### 修改 - 移除 unsafeBitCast 改用安全轉換

在 `unsafeBitCast` 前增加 `CFArrayGetCount(attachments) > 0` 與 `rawPtr` nil 檢查，
確保只有有效指標才進行轉換。

---

## 修復 sendlog() 雙重快取不同步導致日誌靜默丟棄

### 問題 - sendlog 雙快取不同步丟 log

`Event.swift` 中的 `sendlog()` 依賴全局變數 `logState` / `onlogState`，這兩個變數
只在 `updateLogFixState()` / `updateONLogFixState()` 被調用時更新。
若 Extension 啟動時值尚未同步，即使 App 端已設為 true，擴展端仍認為 false，所有日誌被靜默丟棄。

### 修改 - 統一 sendlog 雙快取

- 移除 `logState`、`onlogState` 全局變數及 `lastlogT`/`IntTime`
- `sendlog()` 改為直接讀取 `RPConfig.shared.enableLog` 與 `RPConfig.shared.onLogPage`
- `updateLogFixState()` / `updateONLogFixState()` 簡化為僅記錄日誌

---

## 修復 RTMP / Socket 重連耗盡後永久終止

### 問題 - RTMP/Socket 重連耗盡後永久終止

- RTMP 重連（`SampleHandler.swift`）上限 5 次 → 調用 `stopBroadcastWithError` 永久關閉推流
- Socket 重連（`ReplyKIT/Socket.swift`）上限 10 次 → 永久放棄重連

### 修改 - 重連耗盡改為持續重試

超過上限後不退避，改為 **固定 30 秒間隔持續重連**，不再終止推流或放棄連線：

| 組件 | 上限後行為 (改前) | 上限後行為 (改後) |
| ------ | ------------------ | ------------------ |
| RTMP | `stopBroadcastWithError("RTMP 重連失敗")` | 每 30s 持續嘗試 |
| Socket | `return` (放棄) | 每 30s 持續嘗試 |

---

## 修復 RemoteLogBuffer 滿時無告警

### 問題 - RemoteLogBuffer 滿無告警

`RemoteLogBuffer` 最多暫存 300 筆，滿時靜默丟棄最舊日誌，無任何提示。

### 修改 - 加入滿載告警

每丟棄 50 條記錄一次 `sendlog("⚠️ RemoteLogBuffer 已滿")` 告警。

---

## 新增 TTSService 監聽音頻服務丟失

### 問題 - 音頻服務丟失未處理

`TTSService` 只監聽 `mediaServicesWereResetNotification`，缺少
`mediaServicesWereLostNotification`，無法在第一時間感知音頻服務中斷。

### 修改 - 監聽音頻服務中斷事件

新增 `AVAudioSession.mediaServicesWereLostNotification` 監聽，中斷時記錄日誌，
後續由 `mediaServicesWereResetNotification` 自動恢復。

---

## 修復首次 RTMP 連線容易失敗 (mediaMixer 時序競爭)

### 問題 - configureMediaMixer 早於 RTMP connect

`broadcastStarted()` 中 `configureMediaMixer()` 在 RTMP connect **之前**就呼叫了
`mediaMixer.startRunning()`，導致混音器立即開始產出 frame，但此時 RTMP 連線尚未建立。
HaishinKit 的 TCP timeout 為 15 秒，在這段期間 frame 持續積累，可能造成第一個 connect
超時失敗，進而仰賴重連機制才成功。

### 變更 (`SampleHandler.swift`)

| 位置 | 修正前 | 修正後 |
| ------ | -------- | -------- |
| `configureMediaMixer()` | `addOutput` + **`startRunning`** | 只保留 `addOutput` |
| `startRTMP()` 成功後 | (無) | 新增 `startRunning` |
| `attemptReconnect()` 成功後 | `addOutput` 後無 `startRunning` | `addOutput` + **`startRunning`** |

重連路徑也補上 `startRunning()`，避免極端情況（首次連線從未成功）下 mixer 永遠不啟動。

---

## 修復主 App 記憶體持續增長問題

### 問題 - 主 App 記憶體持續增長

經實機監測發現主 App RAM 用量持續穩定上升，即使無明顯操作也不回落。

### 根因分析 - 記憶體持續增長根因

全面審查所有 liveAPP target 中的集合類、緩衝區、定時器與單例，共找出以下記憶體洩漏或無界增長點：

| 嚴重性 | 問題 | 位置 | 說明 |
| -------- | ------ | ------ | ------ |
| 🔴 | `ConfigManager.layers` 無界增長 | `liveAPP/Config.swift:13` | 每次 `push()` 永久追加新層，無 `pop()` 或容量上限 |
| 🔴 | `pendingFailedPayloads` 只增不減 | `liveAPP/Socket.swift:1111` | 斷線時暫存未送出 payload，但 `suspend()` / `releaseMemory()` / `stopInternal()` 皆未清理 |
| 🟠 | `stopInternal()` 漏清多個字典 | `liveAPP/Socket.swift:1198` | 關閉 Socket 時未釋放 `sendQueues`、`sendingFlags`、`pendingFailedPayloads` |
| 🟢 | `SocketServer` 缺 `deinit` | `liveAPP/Socket.swift` | listener 與 idleTimers 在物件釋放時無法自動取消 |

經檢查後確認已受控（無須修正）：

- `RemoteLogBuffer.buffer` → 上限 300 條，drain 後移除，失敗不回插
- `LogBuffer.buffer` → batch 100 條排出，排完 removeFirst
- `messageLines` → 上限 10000 行，超過砍半至 5000
- `PiPImageCache.inFlightTasks` → `finishDownload()` 正確清理
- `Socket.receiveBuffers` → `removeConnection()` / `suspend()` 皆有清理
- `LogModel.messages` → 上限 1000 條，超出移除最舊
- `OrientationObserver` → 單例存活整段 app 生命週期，observer 無須移除

### 修改 - 釋放暫存並修正洩漏

| 檔案 | 變更 |
| ------ | ------ |
| `liveAPP/Config.swift` | `push()` 加入 `maxLayers=10`，超出時移除最舊層（保留第 0 層 default） |
| `liveAPP/Socket.swift` | `suspend()` / `releaseMemory()` / `stopInternal()` 三處補上 `pendingFailedPayloads.removeAll()` |
| `liveAPP/Socket.swift` | `stopInternal()` 補上 `sendQueues.removeAll()` + `sendingFlags.removeAll()` |
| `liveAPP/Socket.swift` | 新增 `deinit`，取消 idleTimers 與 listener |

---

## 新增 HEVC 編碼支援

### 問題 - 僅支援 H.264

先前僅支援 H.264 編碼，無法利用 HEVC（H.265）的更高壓縮率與 10-bit 色深支援。

### 修改 - 新增 HEVC 編碼設定

**`liveAPP/ContentView.swift`**

- 新增 `HEVCProfile` 列舉（Main / Main10 / Main42210）
- 編碼配置 UI 改為 segmented control 切換 H264 / HEVC，動態顯示對應的 profile picker

**`ReplyKIT/Event.swift`**

- `State` 新增 `videoCodec` 與 `hevcLevel` 欄位
- `updateState()` 與 `init()` 同步載入

**`ReplyKIT/SampleHandler.swift`**

- `h264ProfileLevelString()` → `profileLevelString()`，新增 HEVC 分支（回傳 `kVTProfileLevel_HEVC_Main_AutoLevel` 等常數）
- `applyAllVideoSettings()` 在 HEVC 模式自動將 `bitRateMode` 強制設為 `.variable`（HEVC 建議搭配 VBR）

#### Socket

- `liveAPP/Socket.swift` / `ReplyKIT/Socket.swift` 新增 `videoCodec` 與 `hevcLevel` 欄位傳遞

### 行為

| 編碼格式 | profileLevel | bitRateMode |
| --------- | ------------- | ------------- |
| H264 | 依使用者選擇（AutoLevel 或自訂 Level） | 使用者設定 |
| HEVC | `kVTProfileLevel_HEVC_Main_AutoLevel` 等（AutoLevel，由系統決定） | 強制 `.variable` |

---

## 擴充 TTS 佇列滿載行為控制選項

### 問題 - TTS 佇列滿載無選項

`TTSQueueOverflowAction` 僅有 `.skipNew`（跳過新訊息）與 `.stopOld`（清空佇列並朗讀新訊息）兩種行為，缺乏「清空待朗讀但不讀新訊息」的選項。

### 修改 - 新增清空待朗讀選項

**`liveAPP/TTSService.swift`**

- `TTSQueueOverflowAction` 新增 `.clearPending = 2`
- `speak()` 新增 `.clearPending` 分支：stopSpeaking + 重置計數 + 釋放音訊 + return（不朗讀新訊息）

**`liveAPP/TTSSettingsView.swift`**

- 佇列滿載 Picker 新增第三選項「清空待朗讀」

### 行為對照

| 選項 | 佇列滿時行為 |
| ------ | ------------- |
| 跳過新訊息（skipNew） | 直接丟棄新訊息 |
| 停止舊的，讀新的先（stopOld） | 停止目前朗讀，清空佇列，朗讀新訊息 |
| 清空待朗讀（clearPending） | 停止目前朗讀，清空佇列，不讀新訊息 |
