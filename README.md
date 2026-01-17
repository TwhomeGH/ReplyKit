# 松鼠🐿️推流

適用於iOS的直播推流應用

![松鼠推流](Docs/main.png)

## TODO 待辦事項

- **子母畫面聊天室**  
  - 實現聊天室畫面以 PiP (Picture-in-Picture) 方式呈現
  - 確保聊天室訊息即時更新與渲染

- **App Group 的替代方案**  
  - 使用 Socket 同步擴展之間的參數變化
  - 研究替代 App Group 的資料共享方法

## 調試用設定

![調試日誌](Docs/log.png)
![調試日誌設定](Docs/logset.png)

## GPU旋轉處理設定

![GPU](Docs/gpuset.png)

### 為什麼需要旋轉處理？

由於原始 **ReplyKit** 只提供直向畫面，若需要橫向畫面，必須進行 GPU 畫面旋轉處理。  

### 可設定參數

- **輸出寬高**：可自定義輸出畫面的寬度與高度。
- **插值方式**：使用 **Bicubic 插值**  
  - 運算較慢，但保留細節更好  
  - 對大動態畫面可減少模糊

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
  
  此選項是給側載用戶
  由於側載AppGroup就不可用
  需要用Socket作為轉送橋梁

  啟用後他會把日誌以Socket送回來
  以及依賴AppGroup更新音量等的部分會用Socket取得新配置


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


## **PIP子母窗口聊天室**

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
    "isMain": true
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
            "isMain": True
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
