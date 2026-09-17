# 松鼠🐿️推流

  適用於iOS的直播推流應用

最近註冊了 愛發電有興趣可以去看看

[愛發電 快樂大松鼠](https://ifdian.net/a/coffee0709)


<p float="left">
  <img src="Docs/main.png" width="45%" />
  <img src="Docs/main2.png" width="45%" />
</p>

> [!WARNING] 
> 說明文件不即時 由於後續更新迭代多次 
> 
> 文檔可能沒有更新 所以實際包含功能會有所區別

## 最新更新

- 2026.07.31 移除 MemoryWarning 監聽設計
- 2026.07.30 Metal Shader 性能優化
- 2026.06.20 語音通話與直播共存

👉 完整變更歷史（新→舊）：[Docs/ChangeHistory.md](Docs/ChangeHistory.md)

## HaishinKit Fork

推流引擎已切換至自行維護的 fork：

- **Repo**: [TwhomeGH/HaishinKitFixSwfit](https://github.com/TwhomeGH/HaishinKitFixSwfit)
- **修正內容**: VBR iOS 13+ 支援、Quality mode、VBV 參數、ABR 演算法改善、NetworkMonitor 擁塞檢測強化
- 完整改動說明請見 [CHANGES.md](https://github.com/TwhomeGH/HaishinKitFixSwfit/blob/main/CHANGES.md)


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


## AltStore 測試

以下示例版本是 **3.9.4**
<!-- you can set the alighnment here to left/center/right -->
<h1 align="left">
<a href="https://stikstore.app/altdirect/?url=https://raw.githubusercontent.com/TwhomeGH/ReplyKit/refs/heads/main/AltStoreTest.json"><img src="https://github.com/StikStore/altdirect/blob/main/assets/png/AltSource_Blue.png?raw=true" target="_blank" width="200">
</a>
<a href="https://github.com/TwhomeGH/ReplyKit/releases/download/3.9.4/liveApp_3.9.4.ipa"><img src="https://github.com/StikStore/altdirect/blob/main/assets/png/Download_Blue.png?raw=true" target="_blank" width="200">
</a>
</h1>

## 贊助支持

本專案為個人開發，致力於提供優質的直播推流應用。為了維持持續開發與更新，我們誠摯邀請您參與贊助支持。

### 贊助管道

目前支援以下贊助方式：

- **Twitch**: [https://twitch.tv/twhomegh](https://twitch.tv/twhomegh)

### 贊助用途

您的贊助將用於：
- 維持開發與更新
- 或支持其他項目開發
- 提升技術研發能力
- 開發新功能與改善體驗

### 感謝您的支持

感謝您對本專案的贊助，您的支持是我們持續開發的重要動力。

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
    - [x] 改善子母聊天室性能：回全 CPU 渲染、移除未使用 GPU/CI 路徑、快取 frame metadata 並降低活動 FPS

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
- **GPU處理寬高**：可自定義GPU旋轉/縮放使用的中間處理寬高
- **配置名稱**：方便辨識用
- **選擇方向**：橫向直向
- **只改輸出寬高[畫布本身]**：開啟後GPU處理最終產物寬高與原始一致
- **輸入緩衝區數量**：太大會碰到擴展運存限制50MB 保持在3或5
- **插值方式**：使用 **Bicubic 插值**  
  - 運算較慢，但保留細節更好  
  - 對大動態畫面可減少模糊
  - 預設不使用 用線性即可

### GPU/畫布分辨率

`dstW`/`dstH` 是 GPU 中間處理尺寸，`odstW`/`odstH` 是最終畫布與 encoder 輸出尺寸。
詳細設計與 preset 對照見 [Docs/video-dimensions.md](Docs/video-dimensions.md)。

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
   
### 圖表凍結修復 (2026/06)

CPU / RAM / Disk I/O 三個即時圖表在長時間開啟或反覆切頁後會停止更新。修正：`DataPoint` ID 從 `UUID()` 改為遞增整數（Charts diff 穩定）、計時器改為 `onAppear`/`onDisappear` 顯式管理、切頁時清空歷史陣列。詳見 `Docs/replykit-core-fixes-summary.md` §10。
  



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

        -	長連線需要注意網路穩定性與錯誤處理，避免程式崩潰。

    5. 心跳訊息

        > [!WARNING]
        > **已移除／不再需要** — 此功能適用於 v11.4.2 之前（永久連線架構）的版本。
        > 自 v11.4.2 起 Socket 改為按需連線（on-demand），連線短暫存活，不再需要心跳保活。
        > 以下說明僅供仍使用舊版架構的參考。

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

# **背景記憶體管理**

iOS 的 Jetsam 機制在記憶體緊張時會終止背景 App。本專案在進入背景時自動釋放非關鍵資源以降低被終止機率。

| 背景釋放項目 | 檔案 | 回收量 |
|-------------|------|-------|
| PiP 圖片快取 | `PIPContent.swift` | ~20MB |
| PiP pixel buffer pool | `PIPService.swift` | ~9MB |
| PiP render timer + pipeline | `PIPService.swift` | ~1MB |
| PiP 訊息圖層 | `PIPContent.swift` | ~2-5MB |
| LogModel 日誌緩衝 | `liveAPPApp.swift` | ~300KB |
| LogView 文字緩衝 | `ContentView.swift` | ~6-7MB |

**預期：** 背景常駐記憶體從 ~90-100MB 降至 ~55-65MB，Jetsam 終止風險顯著降低。**保留資源：** SocketServer（log 管線）、PiP 渲染管線（若子母畫面 active）。詳見 `Docs/replykit-core-fixes-summary.md` §11。

        









