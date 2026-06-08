# 松鼠🐿️推流

  適用於iOS的直播推流應用


<p float="left">
  <img src="Docs/main.png" width="45%" />
  <img src="Docs/main2.png" width="45%" />
</p>

> [!WARNING] 
> 說明文件不即時 由於後續更新迭代多次 
> 
> 文檔可能沒有更新 所以實際包含功能會有所區別


## 問題應對方案 

如果你遇到一些奇怪的問題 可以先看Wiki頁\
有些問題 已被發現記載在此

[常見問題處理方式 - Common Problem Solutions](https://github.com/TwhomeGH/ReplyKit/wiki)

## 重新設計 音訊處理 新增了降噪功能&回音消除

降噪處理增加 以及包含回音處理

> [!WARNING]
> App增益被列為棄用 未來將移除
>
> 由於此項會造成回音消除 處理過頭
> 
> 回音消除的基準應保持原始數據






## 視頻碼率分析 🎬

為了方便直播主或壓片組更便捷地使用，提供了**視頻碼率分析**功能：

- **選取視頻**：支援從相簿或檔案 App 選取視頻
- **詳細碼率資訊**：顯示平均碼率、視頻軌碼率、音頻軌碼率、編碼格式、解析度、幀率等
- **圖表化展示**：使用 Swift Charts 呈現碼率對比柱狀圖與碼率隨時間變化折線圖
- **快速診斷**：協助判斷原始視頻品質，作為直播推流參數配置參考

### 未來計畫

- **壓縮轉碼功能**：提供影片壓縮與轉碼功能，最大化效益，讓直播主與壓片組能直接在 App 內完成影片最佳化


## 最新重寫更新說明

本次針對 `ReplyKIT/rotateNV12.metal` 內的 `rotateNV12_bilinear` 與 `rotateNV12_bicubic` 重新整理了畫面旋轉與縮放對齊邏輯。

主要修正內容如下：

- 將輸出座標回推來源座標的流程改為統一使用中心點計算，避免旋轉時以左上角為基準造成畫面偏移
- 修正 4:3 畫面在 16:9 輸出下進行等比例適應時的對齊問題，例如 `1920x1334 -> 1920x1080` 會正確置中並保留左右黑邊
- 修正 `90` / `270` 度旋轉在目前畫面座標系下上下顛倒的問題
- 讓 `bicubic` 的 Y 平面取樣改回正確的 pixel-space 座標，避免取樣位置錯誤
- 調整 NV12 的 UV plane 寫入方式，改為每個 2x2 區塊只寫一次，避免多個 thread 同時寫入同一個 UV pixel 導致色度對齊不穩

這次重寫的重點是讓 GPU 旋轉後的輸出在不同長寬比、不同方向下都能維持正確的置中、縮放與色度對齊。


[版本標記說明 Version Note](./Docs/version.md)

## 最新修正內容說明

## 修復 Socket 連線穩定性與首次推流解析度錯誤

### 問題描述

1. **首次推流解析度錯誤**：第一次推流時常變成 854x480，而非用戶指定的解析度（如 1920x1080）
2. **Socket 死連接/殘留 Listener**：切換直播後舊連線未完全清理，導致新連線無法正常通訊

### 根因分析

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
- **configureVideo_init()**：當 OD/AD 皆為 0 時，從 App Group UserDefaults 讀取 dstW/dstH 作為 fallback；若仍為 0 則設定 1280x720 預設值
- **configureVideo()**：相同 fallback 邏輯
- **broadcastStarted publish 前**：最終 videoSize 檢查也加入 UserDefaults fallback

## 改進音視頻管道處理

目前音頻帶降噪功能 可選使用Metal加速
當前設計 額外套用自動降級保護 如果GPU忙不過來會嘗試降級到CPU
如果到後面完全處理不過來 會嘗試原始音訊傳送
確保系統在某些異常負載下 能夠保持音訊正常


## 修復 VFR 造成的 PTS 異常與畫面速率抖動

### 問題發現

在分析一段長時間直播錄影時，發現影片從約 **54分30秒** 後出現嚴重的畫面速率異常：

- **ffprobe 分析結果**：`r_frame_rate=60/1`（聲稱 60fps）但 `avg_frame_rate≈100`，metadata 與實際不符
- **封包結構**：約 **70% 的幀是「微幀」**（duration = 0.000011s，僅 1 個 PTS tick），穿插在正常 0.016-0.017s 幀之間
- **觸發點**：~54:30 處編碼器嚴重卡頓（幀間隔高達 1.4s ~ 9.9s），恢復後即進入缺陷模式

### 根因分析

透過原始碼追溯，確認問題出在 **ReplyKIT 音視頻管線的三個設計缺陷**：

| 問題 | 位置 | 影響 |
|------|------|------|
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

#### 3. 恢復 AdaptiveVideoBufferManager

取消註解整份 `AdaptiveVideoBufferManager.swift`，並重新接入 `SampleHandler`：

- 根據處理器核心數初始化 buffer count
- 即時監控 FPS、渲染延遲、幀間隔標準差
- 系統過載時自動提高 buffer（最多 5），空載時降低（最少 3）
- 每 3 秒輸出一次診斷日誌

### 效果

這三層防禦形成完整保護：
- **第一層**：不允許 B-frame 重排序 → PTS 不會被編碼器亂序打亂
- **第二層**：CFR 強制修正 PTS → 無論輸入多亂，輸出永遠是 60fps 節奏
- **第三層**：動態 buffer 管理 → 系統過載時有緩衝空間，避免瞬間崩潰

## 新增重連設計

當直播因網路問題 沒有連線成功 會最多嘗試重連 最多5次
也會顯示在子母窗口上 提示當前重連次數



主要是針對音畫時間軸校正

在最新版本目前加上音軌的PTS校正 雖然說音軌偏移照理說應該不會發生

但考量前幾個版本只對畫面做PTS校正 有概率在某些情況下可能出現異常

所以兩者皆補上了PTS修正


## 最新 PiP 背景存活與渲染效能優化

本次針對 PiP 子母畫面在背景被系統終止、動畫與渲染效能進行全面改善：

### 背景存活修復
- **PIPService**: 放寬 `attachToForegroundWindow` 綁定條件，接受任何已連接的 Scene
- **PIPService**: 新增 `handleMemoryWarning()`、background task 生命週期、app 前景/背景切換時自動重連 displayLayer
- **liveAPPApp.swift**: scenePhase `.background` 時註冊 `beginBackgroundTask`，`init()` 時監聽 Memory Warning 通知
- **Socket.swift**: 新增 `suspend()` / `resume()` / `releaseMemory()`，背景時釋放緩衝區、前景恢復運作

### 動畫迴圈重構
- 移除 `CADisplayLink`，改由 PIPService render timer 統一驅動，消除雙 loop 不同步
- 以 `tickAnimation()` 狀態機取代舊的 step 方法，動畫進行中持續回呼
- 穩定 FPS 策略：動畫中 30fps、有訊息/活動 15fps、閒置 1fps，取代舊的跳 60→衰減機制，消除 FPS 震盪

### Render Pipeline 最佳化
- 跳過 `UIGraphicsImageRenderer` → `CGImage` → `CIImage` → `CIContext.render()` 的兩次 round-trip
- 改為 `CVPixelBufferPool` + 直接 `CGContext(data:)` 將 CALayer tree 渲染到 pixel buffer 記憶體
- 移除不再使用的 GPU renderer、Metal device、CIContext 等 dead code


## AltStore 測試

以下示例版本是 **3.9.4**
<!-- you can set the alighnment here to left/center/right -->
<h1 align="left">
<a href="https://stikstore.app/altdirect/?url=https://raw.githubusercontent.com/TwhomeGH/ReplyKit/refs/heads/main/AltStoreTest.json"><img src="https://github.com/StikStore/altdirect/blob/main/assets/png/AltSource_Blue.png?raw=true" target="_blank" width="200">
</a>
<a href="https://github.com/TwhomeGH/ReplyKit/releases/download/3.9.4/liveApp_3.9.4.ipa"><img src="https://github.com/StikStore/altdirect/blob/main/assets/png/Download_Blue.png?raw=true" target="_blank" width="200">
</a>
</h1>

## 側載用戶說明

> [!WARNING]
> 由於本應用為側載安裝，**App Group 無法使用**，因此改以 **Socket** 作為資料傳遞替代方案。  
> 這可能導致首次啟動時，部分 `UserDefaults` 設定 **未能正確同步**，例如：
>
> - `AppVolume`  
> - `MicVolume`  
> - `Rotate`  
> - `主要與次要字體大小`
>
> 其中 **部分 AppVolume / MicVolume 已做額外修正**，因此首次啟動時不會影響實際使用。
> 主要與次要字體大小也可能丟失 導致子母窗口無法正常顯示訊息是空的
>
> 只需要稍微設置中上下微調即可修正

### Socket 轉送
請先開啟 **Socket 轉送** 功能。  

- 若首次啟動時 **沒有跳出「允許區域網路」權限提示**  
  請先**啟用調試日誌**（此操作會主動觸發本地 Socket 行為，從而喚起系統權限視窗）。  
  啟用後，將 App 從背景完全關閉並重新開啟，以重新觸發權限提示。
  
### GPU 處理方向
首次使用時，請務必 **手動更新一次 GPU 處理方向**。  

- 避免因預設值未正確填入而變成 `0`  
- 手動更新後即可正常套用正確數值



## TODO 待辦事項


- **子母畫面聊天室**  
    - [x] 實現聊天室畫面以 PiP (Picture-in-Picture) 方式呈現
    - [x] 確保聊天室訊息即時更新與渲染
    - [ ] 改善子母聊天室性能 目前性能似乎還是偏異常待改進

- **App Group 的替代方案**  
    - [x] 使用 Socket 同步擴展之間的參數變化
    - [x] 研究替代 App Group 的資料共享方法 目前使用Socket替代

- **視頻碼率分析**
    - [x] 視頻選取（相簿 / 檔案 App）
    - [x] 詳細碼率資訊展示
    - [x] 碼率圖表化（Swift Charts）
    - [ ] 壓縮視頻轉碼功能 以最大化效益
    

## 調試用設定


<p float="left">
  <img src="Docs/log.png" width="45%" />
  <img src="Docs/logset.png" width="45%" />
</p>

## GPU旋轉處理設定

<p float="left">
  <img src="Docs/gpuset.png" width="45%" />
  <img src="Docs/gpuset1.png" width="45%" />
</p>

### 為什麼需要旋轉處理？

由於原始 **ReplyKit** 只提供直向畫面，若需要橫向畫面，必須進行 GPU 畫面旋轉處理。  

### 可設定參數

- **畫布輸出寬高**：可自定義輸出畫面的寬度與高度
- **GPU輸出寬高**：可自定義GPU處理後輸出畫面的寬度與高度
- **配置名稱**：方便辨識用
- **選擇方向**：橫向直向
- **只改輸出寬高[畫布本身]**：開啟後GPU處理最終產物寬高與原始一致
- **輸入緩衝區數量**：太大會碰到擴展運存限制50MB 保持在3或5
- **插值方式**：使用 **Bicubic 插值**  
  - 運算較慢，但保留細節更好  
  - 對大動態畫面可減少模糊
  - 預設不使用 用線性即可

### 參考分辨率對應表

| 寬度 | 高度 | 解析度 |
| --- | --- | --- |
| 1034 | 720  | 720p  |
| 1552 | 1080 | 1080p |

## 音訊設定

![Audio](Docs/audio.png)

在此頁面，你可以：

- **控制麥克風或應用的增益與音量大小**  
- **查看直播時的實際輸出音量**，方便即時監控音訊狀態

## 日誌服務

![LogSet](Docs/SettingLog.png)


- **啟用調試日誌**

  除錯用日誌

- **停用非日誌頁面頻率調整**
  
  停用後在非日誌頁會保持更新

- **啟用畫面旋轉日誌**
  
  啟用後可以查看關於畫面處理信息


- **啟用Socke轉送日誌**

>  [!WARNING]
>  此選項是給側載用戶 由於側載AppGroup就不可用 
>  需要用Socket作為轉送橋梁
>
>  啟用後他會把日誌以Socket送回來
>  以及依賴AppGroup更新音量等的部分會用Socket取得新配置


- **啟用PIP子母窗口**

  PIP的每秒處理張數情況

- **啟用PIP子母窗口訊息處理**

  PIP的收到訊息後處理情況
  
![日誌服務器設定頁面，顯示多個開關選項：啟用PIP子母窗口訊息處理調試日誌、測試娛樂傳輸、Socket管理、停用自動碼率調整、GPU旋轉處理設定、API接口地址設為http://192.168.0.242:3000/post、測試連線和取得視頻輸出設定等功能](Docs/SettingLog2.png)

- **測試擃展通信傳遞**

  用於測試擃展通信情況

- **Socket重連**

  如果Socket斷線 可用於重新連接

- **停用自動碼率調整**

  停用後 不會再根據網路情況調整 保持原設定

- **API 接口地址**

  這只有當你有啟用外部日誌時他才會使用

  通常一般來說你用不到

  主要是接收App調試日誌

  日誌Api服務端參閱: [LogServer.js](https://github.com/TwhomeGH/ReplyKit/blob/main/LogServer.js)


# **設備信息**

![CPUINFO](Docs/DeviceInfo1.png)

該頁面可以快速查看設備的重要信息，包括：

## 螢幕資訊
- 裝置原始屏幕寬高（points / pixels）
- ReplayKit 開播後得到的系統輸出解析度（如 1920×1334）

## CPU / GPU 資訊
- CPU 使用率（App 當前使用率）
- CPU 核心數
- 處理器 / GPU 名稱（如 A14 / Apple M1 GPU）

## 裝置型號
- 裝置代號（如 `iPad13,18`）
- 對應 處理器型號（如 A14 / M1）


## **設備信息 RAM**

![CPUINFO](Docs/DeviceInfo2.png)

## 運行內存 Ram

可以大致看一下 記憶體使用情況

- 總RAM量
- App使用RAM量
  



# **PIP子母窗口聊天室**

  ![PIPChat子母聊天室](Docs/PIPChat.png)

  如何傳遞訊息給子母窗口

  SocketApi服務端參閱以下: 

  - [mysocket.py](https://github.com/TwhomeGH/ReplyKit/blob/main/mysocket.py)

  - [TikTok or Twitch訊息服務端](https://github.com/TwhomeGH/TTWChatMessageServer)
  

## Socket 傳輸說明:

1. 連線資訊

	•	協議：TCP

	•	伺服器 IP / HOST：請填寫App端設備使用的地址

	•	PORT：9322

2. 傳輸格式

    每次發送的資料為 JSON 格式，並以換行符號 \n 作為結束符。

### 範例訊息

```json
{
    "type": "StreamMessage",
    "user": "userName",
    "message": "message_text",
    "img": "https://img.icons8.com/?size=100&id=L8HgZUgz2jWS&format=png&color=000000",
    "giftImg": "https://img.icons8.com/?size=100&id=124077&format=png&color=000000",
    "isMain": true,
    "userNum": 1234,
    "userList": ["A", "B", "C"]
}
```


### 欄位說明


  | 欄位 | 類型 | 說明 |
  | -- | -- | -- |
  | type | String | 消息類型，固定 "StreamMessage" |
  | user | String | 使用者名稱 |
  | message | String | 訊息內容 |
  | img | String | 顯示用戶頭像用 使用圖示 URL |
  | giftImg | String | 贈送禮物圖示 URL |
  | isMain | Boolean | 是否為主要消息 (true/false) |
  | userNum | Number | 可選參數，觀眾數；若有提供，會顯示在 PiP「直播中」標籤旁邊 |
  | userList | Array<String> | 可選參數，觀眾清單；目前會先接收保留，未提供也不影響既有功能 |

  補充說明

  - `userNum` 與 `userList` 都是可選欄位，舊格式只傳 `isMain` 也能正常使用
  - 若 `userNum` 沒有傳入，PiP 不會額外顯示觀眾數標籤
  - `userList` 目前先保留給後續功能使用，現階段不會直接顯示在 PiP 畫面上

---

### 對子母畫面 發送直播開始/結束訊息

直播開始 

```json
{
    "type": "StreamStarting",
}
```


  | 欄位 | 類型 | 說明 |
  | -- | -- | -- |
  | type | String | 接口消息類型 |

---  

直播結束

```json
{
    "type": "Ended",
    "Message":"StreamEnded"
}
```

  | 欄位 | 類型 | 說明 |
  | -- | -- | -- |
  | type | String | 接口消息類型 Ended代表結束 |
  | Message | String | 顯示在子母用的結束訊息 使用預設填 StreamEnded |







3. 發送方式（Python 範例）

    ```python
    import socket
    import json
    import time

    HOST = "伺服器IP"
    PORT = 9322

    def create_connection():
        while True:
            try:
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.connect((HOST, PORT))
                print("Connected to server")
                return s
            except Exception as e:
                print("Connection failed, retrying in 3s...", e)
                time.sleep(3)

    s = create_connection()

    while True:
        message = {
            "type": "StreamMessage",
            "user": "user3333",
            "message": "Hello World",
            "img": "https://img.icons8.com/?size=100&id=L8HgZUgz2jWS&format=png&color=000000",
            "giftImg": "https://img.icons8.com/?size=100&id=124077&format=png&color=000000",
            "isMain": True,
            "userNum": 1234,
            "userList": ["A", "B", "C"]
        }

        try:
            s.sendall((json.dumps(message) + "\n").encode("utf-8"))
            print("Message sent")
        except BrokenPipeError:
            print("Broken pipe! Reconnecting...")
            s.close()
            s = create_connection()
            s.sendall((json.dumps(message) + "\n").encode("utf-8"))

        time.sleep(5)  # 每 5 秒發送一次
        
    ```

4. 長連線建議

    為了提升訊息傳輸的穩定性和效率，建議使用 長連線模式：
	
    1. 保持連線活躍
	
        - 在建立連線後持續使用同一個 socket 發送多條訊息，避免每次發送都重新建立連線。

        -	適合頻繁推送資料的場景，例如直播聊天室、持續訊息流。

    2. 自動重連

        -	伺服器可能因超時或網路波動斷開連線，這時程式會捕獲 BrokenPipeError 自動重連，確保訊息不中斷。

    3.	範例程式特點

        -	使用 create_connection() 函數安全建立 TCP 連線。
      
        - 在無窮迴圈中發送訊息，每次發送前捕獲斷線錯誤。

        -	支援自動重連後繼續發送訊息。

    4.	其他建議

        -	可搭配心跳訊息，定期維持連線活躍。

        -	長連線需要注意網路穩定性與錯誤處理，避免程式崩潰。

    5. 心跳訊息

        為了保持連線活躍，防止伺服器判定連線閒置而斷開，客戶端可以定期發送心跳訊息

        設計上是每60秒會清理一次 所以建議每30秒或在50秒時發一次維持


        -	發送內容：只需發送一個 JSON，type 設為 "heartbeat"，並以 \n 結尾即可。

        -	伺服器行為：收到心跳訊息後會重置 idleTimer，確保連線不被自動關閉。

        欄位說明

        | 欄位 | 類型 | 說明 |
        | -- | -- | -- |
        | type | String | 消息類型，固定 "heartbeat" |

        Python 範例

        ```python
        import socket
        import json
        import time

        HOST = "伺服器IP"
        PORT = 9322

        def create_connection():
            while True:
                try:
                    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    s.connect((HOST, PORT))
                    print("Connected to server")
                    return s
                except Exception as e:
                    print("Connection failed, retrying in 3s...", e)
                    time.sleep(3)

        s = create_connection()

        while True:
            heartbeat = {
                "type": "heartbeat"
            }

            try:
                s.sendall((json.dumps(heartbeat) + "\n").encode("utf-8"))
                print("Heartbeat sent")
            except BrokenPipeError:
                print("Broken pipe! Reconnecting...")
                s.close()
                s = create_connection()
                s.sendall((json.dumps(heartbeat) + "\n").encode("utf-8"))

            time.sleep(30)  # 每 30 秒發送一次
        ```

        








