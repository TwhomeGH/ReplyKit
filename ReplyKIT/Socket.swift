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

extension SocketClient.JSONValue {
    var rawValue: Any? {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .object(let v):
            return v.mapValues { $0.rawValue }
        case .array(let v):
            return v.map { $0.rawValue }
        case .null:
            return nil
        }
    }
}


class SocketClient {

    static let shared = SocketClient()

    private var requestCompletionHandlers: [(Any?) -> Void] = []

    private var rtmpCompletionHandlers: [(Bool) -> Void] = []
    private var logConfigCompletionHandlers: [(Bool) -> Void] = []



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
     func setupConnection(host: String = "localhost" , port: UInt16 = 9322) {
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

        guard let con = connection else {
            return
        }

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

    func retry() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in

            self?.connection?.cancel()   // ✅ 先取消舊連線
            self?.setupConnection()      // 重新建立新 connection
            self?.start()
        }
    }



    // MARK: - 發送
    func requestAllSettings() {

        logTo("嘗試請求設定Socket")
        let payload: [String: Any] = ["type": "requestSettings"]
        sendPayload(payload)
    }

    func requestSet(for key:String, type:String) async -> Any? {
        await withCheckedContinuation { continuation in
            self.requestSet(for:key,type: type) { value in
                continuation.resume(returning: value )
            }
        }
    }

    func requestSet(for key:String, type:String,completion: @escaping (Any?) -> Void) {

        requestCompletionHandlers.append(completion)
        logTo("嘗試請求特定設定Socket")
        let payload: [String: Any] = [
            "type": "UPSet",
            "key": key,
            "ValueType":type
        ]
        sendPayload(payload)

    }


    // MARK: - 發送
    func requestRTMPKEY() async -> Bool {
        await withCheckedContinuation { continuation in
            // 呼叫原本 closure 版
            self.requestRTMPKEY { success in
                continuation.resume(returning: success)
            }
        }
    }
    func requestRTMPKEY(completion: @escaping (Bool) -> Void) {

        rtmpCompletionHandlers.append(completion)

        logTo("嘗試請求設定Socket RTMPKEY")
        let payload: [String: Any] = ["type": "requestRTMP"]
        sendPayload(payload)
    }

    func requestLogConfig() async -> Bool {
        await withCheckedContinuation { continuation in
            // 呼叫原本 closure 版
            self.requestLogConfig { success in
                continuation.resume(returning: success)
            }
        }
    }

    func requestLogConfig(completion: @escaping (Bool) -> Void) {
        logConfigCompletionHandlers.append(completion)

        logTo("嘗試請求設定Socket logConfig")
        let payload: [String: Any] = ["type": "logConfig"]
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
        logger.debug("SocketDebug:\(message)")

        sendlog(title:"ReplyKit_Socket",message: message)
    }

    private func sendPayload(_ payload: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: []) , let con = connection else {
            logTo("Socket可能沒上線!")
            return
        }

        // ★ 關鍵：加換行符號當封包結尾
        data.append(0x0A) // '\n'

        
        con.send(content: data, completion: .contentProcessed({ error in

            if let error = error {
                self.logTo("Socket Send error: \(error.localizedDescription)")
            }
        }))

        }




    struct TypePayload: Codable {
        let type:String
    }

    struct RTMPConfig: Codable {
        let type: String
        let rtmpURL: String
        let rtmpKey: String

        let BitRate: Int
        let ChangeBit: Bool
        let h264level: String

        let dstW: Int
        let dstH: Int

        let appVolume: Double
        let micVolume: Double
        let appVolumeAdd: Double
        let micVolumeAdd: Double
    }

    struct LogConfig: Codable {
        let type:String
        let logMode: Int
        let logURL: String
        let onlogPage: Bool
        let onAudioPage: Bool
        let enablelog: Bool
    }

    struct LogMessage: Codable {
        let type:String
        let message: String
    }


    private func applyRTMP(_ c: RTMPConfig) {



        logTo("[Get]RTMP:\(c.rtmpURL):\(fixlogSafeKey(c.rtmpKey))")
        RPConfig.shared.RTMPURL = c.rtmpURL
        RPConfig.shared.RTMPKey = c.rtmpKey

        logTo("[Get]Bit:\(c.BitRate):\(c.ChangeBit)")
        RPConfig.shared.BitRate = c.BitRate
        RPConfig.shared.ChangeBit = c.ChangeBit

        logTo("[Get]H264:\(c.h264level) : \(c.dstW)x\(c.dstH)")
        RPConfig.shared.h264level = c.h264level

        RPConfig.shared.ADWidth = c.dstW
        RPConfig.shared.ADHeight = c.dstH


        logTo(
            "[Get]Audio App:\(c.appVolume) Mic:\(c.micVolume) AppAdd:\(c.appVolumeAdd) MicAdd:\(c.micVolumeAdd)"
        )
        RPConfig.shared.AppVolume = c.appVolume
        RPConfig.shared.MicVolume = c.micVolume

        RPConfig.shared.AppVolumeAdd = c.appVolumeAdd
        RPConfig.shared.MicVolumeAdd = c.micVolumeAdd

        // ✅ 回調通知所有等待的人
        rtmpCompletionHandlers.forEach { $0(true) }
        rtmpCompletionHandlers.removeAll()

    }

    private var receiveBuffer = Data()

    enum JSONValue: Codable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case object([String: JSONValue])
        case array([JSONValue])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let v = try? container.decode(Bool.self) { self = .bool(v); return }
            if let v = try? container.decode(Int.self) { self = .int(v); return }
            if let v = try? container.decode(Double.self) { self = .double(v); return }
            if let v = try? container.decode(String.self) { self = .string(v); return }
            if let v = try? container.decode([String: JSONValue].self) { self = .object(v); return }
            if let v = try? container.decode([JSONValue].self) { self = .array(v); return }
            self = .null
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let v): try container.encode(v)
            case .int(let v): try container.encode(v)
            case .double(let v): try container.encode(v)
            case .bool(let v): try container.encode(v)
            case .object(let v): try container.encode(v)
            case .array(let v): try container.encode(v)
            case .null: try container.encodeNil()
            }
        }
    }



    private func handleJSONPacket(_ data: Data) {
        do {
            let decoder = JSONDecoder()

            // 先只 decode type
            let base = try decoder.decode(TypePayload.self, from: data)

            self.isProcessingRemoteUpdate = true
            defer { self.isProcessingRemoteUpdate = false }

            switch base.type {
            case "testRTMP":
                self.requestRTMPKEY { success in
                    if success {
                    // 這裡 logConfig 已經拿到
                        self.logTo("RTMP 已完成同步")
                    // 可以進行後續流程
                    }
                }
                self.requestLogConfig { success in
                    if success {
                        // 這裡 logConfig 已經拿到
                        self.logTo("LogConfig 已完成同步")
                        // 可以進行後續流程
                    }

                }

            case "UPSet":
                logTo("UPSet結果得到了！")
                // 假設你解析 JSON 得到 resultValue
                let resultValue = try decoder.decode(
                    [String: JSONValue].self,
                    from: data
                )
                let key = resultValue["key"]?.rawValue as? String
                let value = resultValue["value"]?.rawValue

                logTo(
                    "UPGet -> \(String(describing: key)) \(String(describing: value))"
                )
                requestCompletionHandlers.forEach {
                    logTo("⬅️ callback value = \(String(describing: value))")
                    $0(value)
                }  // ✅ 回傳值
                requestCompletionHandlers.removeAll()


            case "logConfig":
                let env = try decoder.decode(LogConfig.self, from: data)
                RPConfig.shared.logMode = env.logMode
                RPConfig.shared.logURL = env.logURL

                RPConfig.shared.onLogPage = env.onlogPage
                RPConfig.shared.onAudioPage = env.onAudioPage
                RPConfig.shared.enableLog = env.enablelog

                RPConfig.shared.applyLogMode()

                logTo("[Get]logMode:\(env.logMode) logURL:\(env.logURL)")
                logTo(
                    "[Get]onLog:\(env.onlogPage) onAudio:\(env.onAudioPage) EnableLog:\(env.enablelog)"
                )

                // ✅ 通知所有等待的 callback
                logConfigCompletionHandlers.forEach { $0(true) }
                logConfigCompletionHandlers.removeAll()

            case "RTMP":
                let env = try decoder.decode(RTMPConfig.self, from: data)
                applyRTMP(env)

            case "log":
                let env = try decoder.decode(LogMessage.self, from: data)
                self.logTo("[Extension] Get \(env.message)")

            default:
                break
            }

        } catch {
            logTo("[Socket]Decode failed ❌ \(error)")
        }
    }

    // MARK: - 接收資料
    private func receive() {

        guard let con = connection else {
            return
        }

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


            self.receiveBuffer.append(data)

            // 2️⃣ 拆包，找到每個 '\n'
            while let range = self.receiveBuffer.firstRange(of: Data([0x0A])) {
                let packet = self.receiveBuffer.subdata(in: 0..<range.lowerBound)
                self.receiveBuffer.removeSubrange(0...range.lowerBound) // 含 '\n'

                // 3️⃣ decode packet
                self.handleJSONPacket(packet)
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
