import socket
import json
import time

HOST = "192.168.0.195"
PORT = 9322

userName = "1阿呵呵呵阿呵呵呵阿呵呵呵阿呵呵呵2阿呵呵呵阿呵呵呵阿呵呵3呵阿呵呵呵阿呵呵呵阿呵呵呵阿4呵呵呵阿呵呵呵阿呵呵呵阿呵呵呵阿呵呵呵測試5"
message_text = "1阿呵呵呵阿呵呵呵2阿呵呵呵阿呵呵呵阿呵呵呵阿呵呵呵阿呵3呵阿呵阿呵呵呵阿呵呵呵阿呵呵呵4阿呵呵呵阿呵呵呵阿呵呵呵測試5"

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

try:
    while True:
        message = {
            "type": "StreamMessage",
            "user": userName,
            "message": message_text,
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
            s = create_connection()  # 重新建立連線
            s.sendall((json.dumps(message) + "\n").encode("utf-8"))
            print("Message sent after reconnect")

        time.sleep(5)

except KeyboardInterrupt:
    print("Closing connection")
finally:
    s.close()