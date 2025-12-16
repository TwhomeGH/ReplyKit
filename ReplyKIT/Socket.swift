//
//  Socket.swift
//  liveAPP
//
//  Created by user on 2025/11/3.
//

import Foundation
import Network

extension Notification.Name {
    static let didReceiveSettings = Notification.Name("didReceiveSettings")
}

class SocketClient {

    static let shared = SocketClient()

    private var connection: NWConnection?
    private var reconnectTimer: Timer?
    private let queue = DispatchQueue(label: "SocketClientQueue")

    // 避免循環更新 UserDefaults
    private var isProcessingRemoteUpdate = false

    init(host: String = "localhost", port: UInt16 = 9322) {
        setupConnection(host: host, port: port)
        //observeLocalChanges()
        sendlog(message: "test socket!!!")
    }

    // MARK: - 連線初始化
     func setupConnection(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        start()
    }

    func closeConnection() {
       
        connection?.cancel()
        connection = nil

        //stopObservingLocalChanges()

    }
    
    func start() {

        guard let con = connection else { return }

        con.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                sendlog(message:"SocketClient connected")

                self.receive()
            case .failed(let error):
                logTo("SocketClient failed: \(String(describing: error))")
                self.retry()
            case .cancelled:
                logTo("SocketClient cancelled")
                self.retry()
            default:
                break
            }
        }
        con.start(queue: queue)
    }

    private func retry() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.start()
        }
    }

    // MARK: - 發送
    func requestAllSettings() {

        logTo("嘗試請求設定Socket")
        let payload: [String: Any] = ["type": "requestSettings"]
        sendPayload(payload)
    }

    // MARK: - 發送
    func requestRTMPKEY() {

        logTo("嘗試請求設定Socket RTMPKEY")
        let payload: [String: Any] = ["type": "requestRTMP"]
        sendPayload(payload)
    }

    func sendSettings(key: String, value: Any) {
        let payload: [String: Any] = [
            "type": "settings",
            "key": key,
            "value": safeJSONValue(value)
        ]
        sendPayload(payload)
    }

    func sendLog(title: String = "Extension", message: String) {
        LogManager.shared.log(title: title, message: message)
        let payload: [String: Any] = [
            "type": "log",
            "message": "\(title): \(message)"
        ]
        sendPayload(payload)
    }

    func logTo(_ message:String){
        sendlog(title:"ReplyKit_Socket",message: message)
    }

    private func sendPayload(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) , let con = connection else { return }


        con.send(content: data, completion: .contentProcessed({ _ in }))
    }

    // MARK: - 接收資料
    private func receive() {

        guard let con = connection else { return }

        con.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                [weak self] data,
                _,
                isComplete,
                _ in
            guard let self = self else { return }

            defer {
                if !isComplete {
                    self.receive()
                }
            }

            guard let data = data else {
                self.retry()
                return
            }

            if let dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let type = dict["type"] as? String {

                self.isProcessingRemoteUpdate = true
                defer { self.isProcessingRemoteUpdate = false }

                switch type {
                case "RTMP":
                    if let key = dict["rtmpURL"] as? String,
                       let value = dict["rtmpKey"] as? String {

                        logTo("Get RTMPURL:\(key) : \(value)")
                        RPConfig.shared.RTMPURL = key
                        RPConfig.shared.RTMPKey = value
                    }

                case "settings":
                    if let key = dict["key"] as? String,
                       let value = dict["value"] {
                        //SharedDefaults.group?.set(value, forKey: key)
                        NotificationCenter.default.post(name: .didReceiveSettings, object: nil)
                        logTo("Updated UserDefaults: \(key) = \(String(describing: value))")
                    }

                case "log":
                    if let message = dict["message"] as? String {
                        sendlog(title: "[Extension] Get", message: message)
                    }
                default:
                    break
                }
            }
        }
    }

    private var localChangesObserver: NSObjectProtocol?

    // MARK: - 監聽本地 UserDefaults
    private func observeLocalChanges() {
        localChangesObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, !self.isProcessingRemoteUpdate else { return }
            let defaults = UserDefaults.standard
            for (key, value) in defaults.dictionaryRepresentation() {
                self.sendSettings(key: key, value: value)
            }
        }

    }

    private func stopObservingLocalChanges() {
        if let observer = localChangesObserver {
            NotificationCenter.default.removeObserver(observer)
            localChangesObserver = nil
        }
    }

    // MARK: - 初次同步
    private func sendInitialUserDefaults() {
        let defaults = UserDefaults.standard
        for (key, value) in defaults.dictionaryRepresentation() {
            sendSettings(key: key, value: value)
        }
    }

    // MARK: - JSON 安全轉換
    private func safeJSONValue(_ value: Any) -> Any {
        switch value {
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let url as URL:
            return url.absoluteString
        case let data as Data:
            return data.base64EncodedString()
        case let dict as [String: Any]:
            return dict.mapValues { safeJSONValue($0) }
        case let array as [Any]:
            return array.map { safeJSONValue($0) }
        default:
            return value
        }
    }
}
