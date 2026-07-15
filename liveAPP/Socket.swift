import Foundation
import Network
import os


//let logger = Logger(subsystem: "nuclear.liveAPP", category: "SocketServer")


extension SocketServer.JSONValue {
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

class SocketServer:ObservableObject {

    // MARK: - Properties

    static let shared = SocketServer()

    static let maxBufferSize = 1_048_576
    static let maxConnections = 10

    private var receiveBuffers: [ObjectIdentifier: Data] = [:]

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var lastReceiveTimes: [ObjectIdentifier: Date] = [:]
    private var keepaliveTimer: DispatchSourceTimer?

    private let queue = DispatchQueue(
                                      label: "SocketServerQueue",
                                      qos:.utility
                          )
    private let queueKey = DispatchSpecificKey<Void>()

    private func performOnQueue(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            block()
        } else {
            queue.async(execute: block)
        }
    }

    private var currentRestartKey: String?

    @Published private(set) var isStopping = false

    private var lastRestartTime: Date?

    private func scheduleRestart(delay: TimeInterval = 1.5) {
        guard !isStopping else { return }

        if let last = lastRestartTime, Date().timeIntervalSince(last) < 3.0 {
            logTo("Restart skipped to avoid rapid restart")
            return
        }
        lastRestartTime = Date()

        let restartKey = "restart_\(UUID().uuidString)"
        currentRestartKey = restartKey
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.currentRestartKey == restartKey else { return }
            self.logTo("Restarting SocketServer...")
            self.stopInternal()
            self.start()
        }
    }

    // MARK: - C callback
    private static let sockerRestartCallback: CFNotificationCallback = {
 _,
 observer,
 _,
        _,
        _ in
        guard let observer else { return }

        let mySelf = Unmanaged<SocketServer>.fromOpaque(observer).takeUnretainedValue()


        mySelf.start()
        mySelf.logTo("Socket服務器可能已失效重建中!")

    }


    init() {
        queue.setSpecific(key: queueKey, value: ())

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            SocketServer.sockerRestartCallback,
            "liveAPP.SocketRestart" as CFString,
            nil,
            .deliverImmediately
        )

    }

    // MARK: - Deinit Socket Server
    deinit {

        listener?.cancel()

        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            CFNotificationName("liveAPP.SocketRestart" as CFString),
            nil
        )
        
        logTo("Socket Server deinit is Call CleanUP")
        stop()

    }


    enum IdleReason {
        case noClientSinceStart
        case lastClientDisconnected
    }


    var isNotifyApp:Bool {
        return userDefaults?.bool(forKey: "isNotifyChat") ?? false
    }

    var isRunning: Bool {
        guard let listener else {
            return false
        }

        switch listener.state {
        case .ready:
            return true
        default:
            return false
        }
    }

    func cleanupStaleListener() {
        guard let listener = self.listener else {
            isStopping = true
            return
        }
        switch listener.state {
        case .ready:
            isStopping = false
        case .waiting:
            logTo("listener 狀態 waiting，保留等待")
            isStopping = false
        case .failed(let error):
            logTo("listener 狀態 failed: \(error)")
            listener.stateUpdateHandler = nil
            listener.cancel()
            self.listener = nil
            isStopping = true
        case .cancelled:
            logTo("listener 狀態 cancelled")
            listener.stateUpdateHandler = nil
            listener.cancel()
            self.listener = nil
            isStopping = true
        default:
            logTo("listener 狀態非 ready，清理中")
            listener.stateUpdateHandler = nil
            listener.cancel()
            self.listener = nil
            isStopping = true
        }
    }


    
    // MARK: - start
    func start(port: UInt16 = 9322) {
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            queue.async { [weak self] in
                self?.start(port: port)
            }
            return
        }

        cleanupStaleListener()

        guard !isRunning else {
            logTo("SocketServer already running")
            return
        }

        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            isStopping = false
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            listener?.start(queue: queue)

            listener?.stateUpdateHandler = { [weak self] state in
                guard let self else { return }

                switch state {
                case .ready:
                    self.logTo("Listener ready")
                    self.isStopping = false

                case .failed(let error):
                    self.logTo("Listener failed: \(error)")
                    self.listener?.cancel()
                    self.listener = nil
                    self.scheduleRestart()

                case .cancelled:
                    self.logTo("Listener cancelled")
                    self.listener = nil

                default:
                    break
                }
            }

            logTo("SocketServer started on port \(port)")

        } catch {
            logTo("SocketServer start failed: \(error)")
            scheduleRestart()
        }


    }

    func logTo(_ mes:String,title:String? = nil){
        if let title {
            sendlog(title:title,message: "\(mes)")
        } else {
            sendlog(message: "\(mes)")
        }

    }

    func ensureRunning() {
        performOnQueue { [weak self] in
            guard let self else { return }
            if self.listener == nil {
                self.logTo("Listener missing, restarting")
                self.scheduleRestart(delay: 1.0)
            } else if case .failed = self.listener?.state {
                self.logTo("Listener in failed state, restarting")
                self.stopInternal()
                self.start()
            }
        }
    }

    // MARK: - Handle New Connection
    private func handleNewConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)

        if connections.count >= SocketServer.maxConnections {
            logTo("Max connections (\(SocketServer.maxConnections)) reached, rejecting new connection")
            connection.cancel()
            return
        }

        connections[id] = connection
        lastReceiveTimes[id] = Date()

        if connections.count == 1 {
            startKeepaliveTimer()
        }
        
        logTo("New connection added. Total connections: \(self.connections.count)")

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }

            switch state {
            case .ready:

                if self.connections[ObjectIdentifier(connection)] != nil {
                    self.logTo("Connection ready: \(connection)")
                    self.replayFailedPayloads(for: connection)

                }


      
            case .failed(let error):
                self.logTo("Connection failed: \(error.localizedDescription)")
                self.removeConnection(connection)

                if self.connections.isEmpty {
                    self.logTo("All connections lost, ensuring listener alive")
                    self.ensureRunning()
                }

            case .cancelled:
                self.logTo("Connection cancelled")
                self.removeConnection(connection)
            default:
                break
            }
        }


        receiveBuffers[id] = Data()

        connection.start(queue: queue)
        startReceiveLoop(for: connection)
    }



    // MARK: - Receive Data
    private var receiveTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    private func startReceiveLoop(for connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        receiveTasks[id]?.cancel()
        receiveTasks[id] = Task { [weak self] in
            await self?.runReceiveLoop(connection: connection, id: id)
        }
    }

    private func stopReceiveLoop(for connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        receiveTasks[id]?.cancel()
        receiveTasks[id] = nil
    }

    private func runReceiveLoop(connection: NWConnection, id: ObjectIdentifier) async {
        guard connections[id] != nil else { return }

        while !Task.isCancelled {
            guard connections[id] != nil else { break }

            let result: (data: Data?, isComplete: Bool, error: NWError?)
            do {
                result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool, NWError?), Error>) in
                    guard connections[id] != nil else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                        continuation.resume(returning: (data, isComplete, error))
                    }
                }
            } catch {
                break
            }

            guard connections[id] != nil else { break }

            if let data = result.data, !data.isEmpty {
                self.lastReceiveTimes[id] = Date()
                var buffer = self.receiveBuffers[id] ?? Data()

                if LPConfig.shared.SocketLog {
                    logger.debug("Socket received \(data.count) bytes")
                }

                buffer.append(data)

                if buffer.count > SocketServer.maxBufferSize {
                    logTo("[\(id)] Buffer exceeded \(SocketServer.maxBufferSize) bytes, closing connection")
                    removeConnection(connection)
                    return
                }

                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[..<newlineIndex]
                    let removeCount = buffer.distance(from: buffer.startIndex, to: buffer.index(after: newlineIndex))
                    buffer.removeFirst(removeCount)
                    guard !lineData.isEmpty else { continue }
                    handleReceivedData(Data(lineData), from: connection)
                    guard connections[id] != nil else { return }
                }

                if connections[id] != nil {
                    receiveBuffers[id] = buffer
                }
            }

            guard connections[id] != nil else { break }

            if let error = result.error {
                logTo("Receive error: \(error)")
                removeConnection(connection)
                return
            }

            if result.isComplete {
                if connections[id] != nil, let buffer = receiveBuffers[id], !buffer.isEmpty {
                    handleReceivedData(buffer, from: connection)
                }
                receiveBuffers[id] = nil
                removeConnection(connection)
                return
            }
        }
    }
    

    func debugRTMP() {
        let rtmpPayload: [String: Any] = GetRTMPConfig()
        
        queueSend(payload: rtmpPayload)

    }

    private var lastMessageTime: Date = .distantPast
    private let messageThrottleInterval: TimeInterval = 0.05



    struct TypePayload: Codable {
        let type:String
    }
    struct StreamEnded: Codable {
        let Message:String
    }

    struct BatchRequest: Codable {
        let requests: [String]
        let data: [String: String?]?

    }


    struct ChatMessage: Codable {
        let user:String
        let message:String
        let img:String?
        let giftImg:String?
        var isMain:Bool?
        let userNum: Int?
        let userList: [String]?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            user = try container.decode(String.self, forKey: .user)
            message = try container.decode(String.self, forKey: .message)
            img = try container.decodeIfPresent(String.self, forKey: .img)
            giftImg = try container.decodeIfPresent(String.self, forKey: .giftImg)
            isMain = try container.decodeIfPresent(Bool.self, forKey: .isMain)
            userList = try container.decodeIfPresent([String].self, forKey: .userList)
            if let intVal = try? container.decodeIfPresent(Int.self, forKey: .userNum) {
                userNum = intVal
            } else if let strVal = try container.decodeIfPresent(String.self, forKey: .userNum) {
                userNum = Int(strVal)
            } else {
                userNum = nil
            }
        }
    }
    struct SLogMessage:Codable {
        let title:String
        let message:String
    }
    struct LogBatchPayload: Codable {
        let entries: [String]
    }
    struct UPSet:Codable {
        let key:String
        let ValueType:String
    }

    struct AudioLive:Codable {
        var appVol:Float
        var micVol:Float
        var persist:Bool = false
    }

    struct AudiencePayload: Codable {
        let userNum: Int?
        let userList: [String]?
    }


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



    
    func renderChatMessage(
        user: String,
        msg: String,
        img: String?,
        giftImg: String?,
        isMain:Bool = true
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastMessageTime) >= messageThrottleInterval else {
            return
        }
        lastMessageTime = now

        logTo(
            "取得聊天室訊息:\(user):\(msg) Img:\(String(describing: img)) GIFT:\(String(describing: giftImg)) isMain:\(isMain)"
        )


        if isNotifyApp {
            let (cleanBody, inlineImages) = PIPServiceMessages.extractAllImageURLs(from: msg)
            postSystemNotification(title: user, body: cleanBody, imageURL: img, inlineImages: inlineImages)
        }

        PIPService.shared
            .addMessage(
                user:user,
                msg:msg,
                imgURL:img,
                giftURL: giftImg,
                isMain: isMain
            )





    }

    private func updateAudienceInfo(
        userNum: Int?,
        userList: [String]?
    ) {
        var didChange = false

        if let userNum {
            if LPConfig.shared.streamViewerCount != userNum {
                LPConfig.shared.streamViewerCount = userNum
                didChange = true
            }
        }

        if let userList,
            LPConfig.shared.streamViewerList != userList {
            LPConfig.shared.streamViewerList = userList
            didChange = true
        }

        if didChange {
            PIPService.shared.markOverlayDirty()
        }
    }


    // MARK: - 直播狀態管理 開始直播
    func StreamStarting() {

        StreamStatusChanged(isLive: true)

        LPConfig.shared.streamStartTime = Date()

        LPConfig.shared.streamViewerCount = nil
        LPConfig.shared.streamViewerList = []
        
    }

    // MARK: - 直播狀態管理 直播開始/結束 狀態更新
    func StreamStatusChanged(isLive: Bool, message: String? = nil) {
        LPConfig.shared.StreamEnded = !isLive
        LPConfig.shared.StreamEndMes = message ?? (isLive ? "直播中" : "直播已結束")
        PIPService.shared.markOverlayDirty()
    }

    func GetRTMPConfig() -> [String: Any]  {

        var payload: [String: Any] = [
            "type": "RTMP",
            "rtmpURL": userDefaults?.string(forKey: "rtmpURL") ?? "rtmp://192.168.0.102/live",
            "rtmpKey": userDefaults?.string(forKey: "rtmpKey") ?? "test",
            "BitRate": userDefaults?.integer(forKey: "bitRate") ?? 3_900_000,
            "ChangeBit": userDefaults?.bool(forKey: "ChangeBit") ?? false,
            "isLowLatencyRateControlEnabled":userDefaults?.bool(forKey:"isLowLatencyRateControlEnabled") ?? true,
            "useEnhancedRTMP":userDefaults?.object(forKey:"useEnhancedRTMP") as? Bool ?? true,
            "isOringinAudio": (userDefaults?.object(forKey: "isOringinAudio") as? Bool) ?? true,

            "h264level": userDefaults?
                .string(forKey: "h264level") ?? "AutoHigh",
            "videoCodec": userDefaults?
                .string(forKey: "videoCodec") ?? "H264",
            "hevcLevel": userDefaults?
                .string(forKey: "hevcLevel") ?? "Main",
            "BitRateMode": min(userDefaults?
                .integer(forKey: "BitRateMode") ?? 0, 2),

            "videoBuffer": userDefaults?
                .integer(forKey: "BufferCount") ?? 5,

            "useBic": userDefaults?
                .bool(forKey: "useBic") ?? false,


            "dstW": userDefaults?.integer(forKey: "dstW") ?? 0,
            "dstH": userDefaults?.integer(forKey: "dstH") ?? 0,

            "odstW": userDefaults?.integer(forKey: "odstW") ?? 0,
            "odstH": userDefaults?.integer(forKey: "odstH") ?? 0,



            "Rotate": userDefaults?.object(forKey: "Rotate") as? Int ?? 90 ,
            
            "RotateOriginal":userDefaults?.object(forKey: "RotateOriginal") as? Bool ?? false ,
            
            "enableEchoFix" : userDefaults?.bool(forKey: "enableEchoFix") ?? false,
            "enableNoiseFix": userDefaults?.bool(forKey: "enableNoiseFix") ?? false,
            "enableAGCFix" : userDefaults?.bool(forKey: "enableAGCFix") ?? false,
            "enableMetalAudio": userDefaults?.bool(forKey: "enableMetalAudio") ?? false,
            


            "appVolume": userDefaults?
                .double(forKey: "appVolume") ?? 1.0,
            "micVolume": userDefaults?
                .double(forKey: "micVolume") ?? 1.0,

            "appVolumeAdd": userDefaults?
                .double(forKey: "appAddVolume") ?? 1.0,
            "micVolumeAdd": userDefaults?
                .double(forKey: "micAddVolume") ?? 1.0,

            "KeyFrameInterval": userDefaults?
                .integer(forKey: "KeyFrameInterval") ?? 2,
            "enableRTMPLog": userDefaults?
                .bool(forKey: "enableRTMPLog") ?? false,

        ]

        sendlog(message: "降噪設定 enableNoiseFix:\(String(describing: payload["enableNoiseFix"]))")

        if let BCount = payload["videoBuffer"] as? Int {
            if BCount < 1 {
                userDefaults?.set(3, forKey: "BufferCount")
                payload["videoBuffer"] = 3
                sendlog(message: "修正BufferCount -> 3")
            }
        }

        if let AppVol = payload["appVolume"] as? Double {
            if AppVol == 0.0 {
                userDefaults?.set(1.0, forKey: "appVolume")
                payload["appVolume"] = 1.0
                sendlog(message: "修正AppVol -> 1.0")
            }
        }

        if let micVol = payload["micVolume"] as? Double {
            if micVol == 0.0 {
                userDefaults?.set(1.0, forKey: "micVolume")
                payload["micVolume"] = 1.0
                sendlog(message: "修正MicVol -> 1.0")
            }
        }

        if let AppVol = payload["appVolumeAdd"] as? Double {
            if AppVol == 0.0 {
                userDefaults?.set(1.0, forKey: "appAddVolume")
                payload["appVolumeAdd"] = 1.0
                sendlog(message: "修正AppVolAdd -> 1.0")
            }
        }

        if let micVolAdd = payload["micVolumeAdd"] as? Double {
            if micVolAdd == 0.0 {
                userDefaults?.set(1.0, forKey: "micAddVolume")
                payload["micVolumeAdd"] = 1.0
                sendlog(message: "修正MicVolAdd -> 1.0")
            }
        }


        // 每次請求RTMP都重置直播狀態
        StreamStarting()
        
        var CPayloadKey = payload

        if let key = payload["rtmpKey"] as? String {
            CPayloadKey["rtmpKey"] = fixlogSafeKey(key)
        }


        logTo("RTMP DebugRTMP[Socket]\(CPayloadKey)")


        return payload
    }

    func GetLogConfig() -> [String: Any]  {
        let logMode = userDefaults?.integer(forKey: "logMode") ?? 1
        let logURL = userDefaults?
            .string(
                forKey: "logURL"
            ) ?? "http://192.168.0.242:3000/post"
        let onlogPage = userDefaults?.bool(forKey: "onlogPage") ?? false
        let onAudioPage = userDefaults?.bool(forKey: "onAudioPage") ?? false
        let enableLog = userDefaults?.bool(forKey: "Enablelog") ?? false
        let enableSocketLog = userDefaults?.bool(forKey: "EnableSocketlog") ?? false
        let enableTimeDebug = userDefaults?.bool(forKey: "EnableTimeDebug") ?? false
        let enablePipelineLog = userDefaults?.bool(forKey: "EnablePipelineLog") ?? false

        LPConfig.shared.logMode = logMode
        LPConfig.shared.logURL = logURL
        LPConfig.shared.onLogPage = onlogPage
        LPConfig.shared.enableLog = enableLog
        LPConfig.shared.SocketLog = enableSocketLog

        let payload: [String: Any] = [
            "type": "logConfig",
            "logMode": logMode,
            "logURL": logURL,
            "onlogPage": onlogPage,
            "onAudioPage": onAudioPage,
            "enableLog": enableLog,
            "enableSocketLog": enableSocketLog,
            "enableTimeDebug": enableTimeDebug,
            "enablePipelineLog": enablePipelineLog,



        ]
        logTo("RTMP DebugLogConfig[Socket]\(payload)")

        return payload

    }

    let decoder = JSONDecoder()

    private func handleReceivedData(_ data: Data, from connection: NWConnection) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let base = try decoder.decode(TypePayload.self, from: data)
                self.handleDecodedPayload(data: data, type: base.type, connection: connection)
            } catch {
                self.logTo("[Socket]Decode failed ❌ \(error)")
                self.removeConnection(connection)
            }
        }
    }



    private func handleDecodedPayload(data: Data, type: String, connection: NWConnection) {
        do {
            

            switch type {

            case "heartbeat":
                sendlog(message: "收到Socket心跳維持連線")

            case "StreamStarting":
                sendlog(message: "直播開始")
                StreamStarting()

            case "Ended":
                let dict = try decoder.decode(StreamEnded.self, from: data)
                let MES = dict.Message
                sendlog(message: "直播已結束: \(MES)")
                if MES != "StreamEnded" {
                    StreamStatusChanged(isLive: false, message: MES)
                } else {
                    StreamStatusChanged(isLive: false)
                }

            case "StreamMessage":
                let dict = try decoder.decode(ChatMessage.self, from: data)
                let user = dict.user
                let msg = dict.message
                let img = dict.img
                let giftImg = dict.giftImg
                let isMain = dict.isMain ?? true
                let userNum = dict.userNum
                let userList = dict.userList

                updateAudienceInfo(userNum: userNum, userList: userList)

                guard !user.isEmpty, !msg.isEmpty else {
                    logTo("訊息是空的 不需要更新子母_StreamMessage")
                    return
                }

                renderChatMessage(user: user, msg: msg, img: img, giftImg: giftImg, isMain: isMain)

                Task { @MainActor in
                    TTSService.shared.speakStreamMessage(user: user, message: msg, isMain: isMain)
                }

            case "UPSet":
                let dict = try decoder.decode(UPSet.self, from: data)
                let key = dict.key
                let VType = dict.ValueType

                var res: Any?
                switch VType {
                case "String":
                    res = userDefaults?.string(forKey: key)
                case "Bool":
                    res = userDefaults?.object(forKey: key) as? Bool
                case "Double":
                    res = userDefaults?.object(forKey: key) as? Double
                case "Int":
                    res = userDefaults?.object(forKey: key) as? Int
                case "Float":
                    res = userDefaults?.object(forKey: key) as? Float
                default:
                    logTo("Unknown UPSet type: \(VType)")
                    return
                }

                guard let result = res else {
                    logTo("UPSet key '\(key)' not found or type mismatch")
                    sendTo(connection, payload: ["type": "UPSet", "key": key, "value": NSNull()])
                    return
                }

                sendTo(connection, payload: ["type": "UPSet", "key": key, "value": result])

            case "batch":
                let json = try JSONSerialization.jsonObject(with: data)
                sendlog(message: "liveAppBactch Raw:\n\(json)")

                let dict = try decoder.decode(BatchRequest.self, from: data)
                let requests = dict.requests
                sendlog(message: "liveAppBactch Req:\n\(requests)")

                let batchData = dict.data
                sendlog(message: "liveAppBactch Req:\n\(String(describing: batchData))")

                var responses: [[String: Any]] = []
                for req in requests {
                    switch req {
                    case "requestRTMP":
                        responses.append(GetRTMPConfig())
                    case "logConfig":
                        responses.append(GetLogConfig())
                    case "log":
                        if let batchData = batchData {
                            for (key, value) in batchData {
                                logTo(String(describing: value), title: String(describing: key))
                            }
                        } else {
                            logTo("data 為 nil")
                        }
                    default:
                        break
                    }
                }
                responses.append(["type": "BatchEnded"])

                for (index, resp) in responses.enumerated() {
                    sendTo(connection, payload: resp)
                    if index == 0, let type = resp["type"] as? String, type == "RTMP" {
                        var logResp = resp
                        if let rtmpKey = logResp["rtmpKey"] as? String {
                            logResp["rtmpKey"] = fixlogSafeKey(rtmpKey)
                        }
                        sendlog(message: "RESBatch-RTMP->\n\(logResp)")
                    } else {
                        sendlog(message: "RESBatch->\n\(resp)")
                    }
                }

            case "logConfig":
                sendTo(connection, payload: GetLogConfig())

            case "requestRTMP":
                sendTo(connection, payload: GetRTMPConfig())

            case "requestSettings":
                logTo("棄用Sync UserDefaults to client 該項目不使用")

            case "audioLive":
                let dict = try decoder.decode(AudioLive.self, from: data)
                LiveVolumeModel.shared.updateVolumes(mic: dict.micVol, app: dict.appVol, persist: dict.persist)
                logTo("Updated UserVol APP:\(dict.appVol) Mic:\(dict.micVol) Persist:\(dict.persist)")

            case "settings":
                let dict = try decoder.decode([String: JSONValue].self, from: data)
                if let key = dict["key"]?.rawValue as? String, let valueAny = dict["value"]?.rawValue {
                    let safeValueStr = String(describing: safeJSONValue(valueAny))
                    logTo("Updated UserDefaults: \(key) = \(safeValueStr)")
                    userDefaults?.set(valueAny, forKey: key)
                    let notificationName: String? = {
                        switch key {
                        case "appVolume": return "appVolumeChanged"
                        case "micVolume": return "micVolumeChanged"
                        case "appAddVolume": return "appAdd"
                        case "micAddVolume": return "micAdd"
                        default: return nil
                        }
                    }()
                    if let name = notificationName {
                        CFNotificationCenterPostNotification(
                            cfCenter,
                            CFNotificationName(name as CFString),
                            nil, nil, true
                        )
                    }
                }

            case "log":
                let dict = try decoder.decode(SLogMessage.self, from: data)
                receiveSocketLog(title: dict.title, message: dict.message)

            case "logbatch":
                let batch = try decoder.decode(LogBatchPayload.self, from: data)
                guard LPConfig.shared.enableLog || LPConfig.shared.SocketLog else { break }
                let prefixed = batch.entries.map { "UseESocket:\($0)" }
                LogBuffer.shared.push(prefixed)
                AppLogPersister.shared.append(lines: prefixed)

            case "audience":
                let dict = try decoder.decode(AudiencePayload.self, from: data)
                updateAudienceInfo(userNum: dict.userNum, userList: dict.userList)

            case "reconnectStatus":
                if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = dict["status"] as? String,
                   let attempt = dict["attempt"] as? Int {
                    LPConfig.shared.reconnectAttempt = attempt
                    let maxAttempts = LPConfig.shared.reconnectMaxAttempts
                    switch status {
                    case "attempting":
                        LPConfig.shared.isReconnecting = true
                        LPConfig.shared.reconnectStatus = "🔄 \(attempt)/\(maxAttempts)"
                    case "success":
                        LPConfig.shared.isReconnecting = false
                        LPConfig.shared.reconnectStatus = ""
                    case "failed":
                        LPConfig.shared.isReconnecting = true
                        LPConfig.shared.reconnectStatus = "❌ \(attempt)/\(maxAttempts)"
                    case "exhausted":
                        LPConfig.shared.isReconnecting = false
                        LPConfig.shared.reconnectStatus = ""
                    default:
                        break
                    }
                    PIPService.shared.markOverlayDirty()
                }

            default:
                logTo("Unknown message type: \(type)")
            }

        } catch {
            self.logTo("[Socket]Decode failed ❌ \(error)")
        }
    }


    private var sendQueues: [ObjectIdentifier: [Data]] = [:]
    private var sendingFlags: [ObjectIdentifier: Bool] = [:]
    private var sendTimeoutFlags: [String: Bool] = [:]


    private func encodedData<T: Encodable>(_ payload: T) -> Data? {
        try? JSONEncoder().encode(payload)
    }


    // MARK: 群播
    func queueSend(payload: some Encodable) {
        guard let data = encodedData(payload) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            for conn in self.connections.values {
                self.enqueue(data, to: conn)
            }
        }
    }

    private func enqueue(_ data: Data, to conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        queue.async {
            var queue = self.sendQueues[id] ?? []
            queue.append(data)
            self.sendQueues[id] = queue

            if self.sendingFlags[id] != true {
                self.sendingFlags[id] = true
                self.sendNextPayload(for: conn)
            }
        }
    }

    private func sendNextPayload(for conn: NWConnection) {
        let id = ObjectIdentifier(conn)


        queue.async {
            guard var queue = self.sendQueues[id], !queue.isEmpty else {
                self.sendingFlags[id] = false
                return
            }

            var data = queue.removeFirst()
            self.sendQueues[id] = queue

            data.append(0x0A)

            let timeoutKey = "send_\(id)"
            self.sendTimeoutFlags[timeoutKey] = true
            self.queue.asyncAfter(deadline: .now() + 30) { [weak self, weak conn] in
                guard let self, let conn else { return }
                guard self.sendTimeoutFlags.removeValue(forKey: timeoutKey) != nil else { return }
                self.logTo("Send timeout (30s), removing connection")
                self.removeConnection(conn)
            }

            conn.send(content: data, completion: .contentProcessed { [weak self] error in

                guard let self = self else { return }
                self.sendTimeoutFlags.removeValue(forKey: timeoutKey)

                if let error {
                    self.removeConnection(conn)
                    self.logTo("Send error: \(error)")
                    return
                }

                self.sendNextPayload(for: conn)
            })
        }
    }



    func broadcast(type:String = "settings",key: String, value: Any,to connection: NWConnection? = nil) {
        var payload: [String: Any] = [
            "type": type,
            "key": key,
            "value": safeJSONValue(value)
        ]

        if type == "log" {
            payload["message"] = value
        }

        if let conn = connection {
            logTo("使用單一廣播")
            sendTo(conn, payload: payload)
        } else {

            logTo("廣播給所有已連線")
            queueSend(payload: payload)
        }


        }


    // MARK: 一對一
    private func sendTo(_ connection: NWConnection, payload: some Encodable) {
        guard let data = encodedData(payload) else { return }
        let id = ObjectIdentifier(connection)
        queue.async {
            var queue = self.sendQueues[id] ?? []
            queue.append(data)
            self.sendQueues[id] = queue

            if self.sendingFlags[id] != true {
                self.sendingFlags[id] = true
                self.sendNextPayload(for: connection)
            }
        }
    }


    // MARK: - Keepalive
    private func startKeepaliveTimer() {
        stopKeepaliveTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.sendKeepalive()
        }
        timer.activate()
        keepaliveTimer = timer
    }

    private func stopKeepaliveTimer() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    private let staleConnectionTimeout: TimeInterval = 60

    private func sendKeepalive() {
        let payload: [String: Any] = ["type": "keepalive"]
        let now = Date()
        for (id, conn) in connections {
            if let lastRx = lastReceiveTimes[id], now.timeIntervalSince(lastRx) > staleConnectionTimeout {
                logTo("Connection stale (no data for \(Int(now.timeIntervalSince(lastRx)))s), removing")
                removeConnection(conn)
                continue
            }
            sendTo(conn, payload: payload)
        }
    }

    // MARK: - Connection Cleanup
    private var pendingFailedPayloads: [ObjectIdentifier: [[String: Any]]] = [:]

    private func removeConnection(_ connection: NWConnection) {
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            queue.async { [weak self] in
                self?.removeConnection(connection)
            }
            return
        }

        let id = ObjectIdentifier(connection)

        guard connections[id] != nil else { return }

        connection.stateUpdateHandler = nil
        connection.cancel()

        if let pendingQueue = sendQueues[id], !pendingQueue.isEmpty {
            pendingFailedPayloads[id] = pendingQueue
            self.logTo("Saved \(pendingQueue.count) pending payloads for re-queue")
        }

        stopReceiveLoop(for: connection)
        connections[id] = nil
        receiveBuffers[id] = nil
        lastReceiveTimes[id] = nil
        sendQueues[id] = nil
        sendingFlags[id] = nil

        if connections.isEmpty {
            stopKeepaliveTimer()
        }

        logTo("Connection removed. Remaining: \(self.connections.count)")
    }

    private func replayFailedPayloads(for connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard let failedPayloads = pendingFailedPayloads.removeValue(forKey: id),
              !failedPayloads.isEmpty else { return }
        self.logTo("Re-playing \(failedPayloads.count) saved payloads")
        for payload in failedPayloads {
            enqueue(payload, to: connection)
        }
    }

    func stop() {
        performOnQueue { [weak self] in
            guard let self else { return }
            self.isStopping = true
            self.stopInternal()
        }
    }


    // MARK: - Suspend / Resume
    func suspend() {
        logTo("SocketServer 暫停（釋放連線但保留 listener）")
        queue.async { [weak self] in
            guard let self = self else { return }
            for (_, conn) in self.connections {
                conn.stateUpdateHandler = nil
                conn.cancel()
            }
            self.connections.removeAll()
            self.receiveBuffers.removeAll()
            self.lastReceiveTimes.removeAll()
            self.sendQueues.removeAll()
            self.sendingFlags.removeAll()
            self.pendingFailedPayloads.removeAll()
        }
    }

    func resume() {
        logTo("SocketServer 恢復（重新監聽）")
        performOnQueue { [weak self] in
            guard let self else { return }
            if self.listener == nil {
                self.start()
            }
        }
    }

    /// 收到 Memory Warning 時釋放 buffer
    func releaseMemory() {
        logTo("SocketServer 釋放 buffer")
        queue.async { [weak self] in
            guard let self = self else { return }
            self.receiveBuffers.removeAll()
            self.lastReceiveTimes.removeAll()
            self.sendQueues.removeAll()
            self.sendingFlags.removeAll()
            self.pendingFailedPayloads.removeAll()
        }
    }


    func stopInternal() {
        for (_, conn) in connections {
            conn.stateUpdateHandler = nil
            conn.cancel()
        }

        listener?.stateUpdateHandler = nil
        listener?.cancel()

        listener = nil

        stopKeepaliveTimer()
        connections.removeAll()
        receiveBuffers.removeAll()
        lastReceiveTimes.removeAll()
        sendQueues.removeAll()
        sendingFlags.removeAll()
        pendingFailedPayloads.removeAll()

        logTo("SocketServer stopped")
    }



    // MARK: - Utils
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


// MARK:日誌內容保護StreamKey不全顯示
func fixlogSafeKey(_ str:String) -> String{
    var g = str
    let replaceCount = min(5, g.count)
    let endIndex = g.index(g.endIndex, offsetBy: -replaceCount)
    let prefix = String(g[..<endIndex])

    if replaceCount > 2 {
        let startOfReplace = g.index(g.endIndex, offsetBy: -replaceCount)
        let midEnd = g.index(g.endIndex, offsetBy: -2)
        let middle = g[startOfReplace..<midEnd]
        g = prefix + middle + "00"
    } else {
        g = String(repeating: "0", count: g.count)
    }

    return g
}
