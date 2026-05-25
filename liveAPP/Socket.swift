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

    private var receiveBuffers: [ObjectIdentifier: Data] = [:]

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private let queue = DispatchQueue(
                                      label: "SocketServerQueue",
                                      qos:.utility
                          )

    private var idleTimers: [ObjectIdentifier: DispatchSourceTimer] = [:]

    private func resetIdleTimer(for conn: NWConnection) {
        let id = ObjectIdentifier(conn)

        if let timer = idleTimers.removeValue(forKey: id) {
            timer.cancel()
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60) // 60 秒沒動靜就踢
        timer.setEventHandler { [weak self] in
            self?.logTo("[\(id)] Idle timeout, closing connection")
            self?.removeConnection(conn)
        }
        timer.resume()

        idleTimers[id] = timer
    }


    private var restartWorkItem: DispatchWorkItem?

    @Published private(set) var isStopping = false

    private var lastRestartTime: Date?

    // MARK: Socket 最後一次活動時間Timer
    private var idleTimerActivity: DispatchSourceTimer?

    func stopActivityIdleTimer() {
        idleTimerActivity?.cancel()
        idleTimerActivity = nil
    }

    func startActivityIdleTimer(
        _ idleTime:TimeInterval = 3600,
        reason:IdleReason = .lastClientDisconnected
    ) {
        idleTimerActivity?.cancel()
        idleTimerActivity = nil

        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + idleTime, repeating: idleTime)

        timer.setEventHandler { [weak self] in
            guard let self else { return }

            self.logTo("Idle timeout reached, shutting down socket Reason:\(reason)")
                self.stop()

        }

        idleTimerActivity = timer
        timer.resume()
    }


    private func scheduleRestart(delay: TimeInterval = 1.5) {
        guard !isStopping else { return }

        if let last = lastRestartTime, Date().timeIntervalSince(last) < 3.0 {
            logTo("Restart skipped to avoid rapid restart")
            return
        }
        lastRestartTime = Date()

        restartWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.logTo("Restarting SocketServer...")
            self.stopInternal()
            self.start()

        }

        restartWorkItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
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

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            SocketServer.sockerRestartCallback,
            "liveAPP.SocketRestart" as CFString,
            nil,
            .deliverImmediately
        )

    }

    deinit {
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

    var isRunning: Bool {
        guard let listener else {
            isStopping = true
            return false
        }

        switch listener.state {
        case .ready:
            logTo("listener 有效!")
            isStopping = false
            return true

        case .failed(let error):
            logTo("listener 狀態 failed: \(error)")
            listener.stateUpdateHandler = nil
            listener.cancel()
            self.listener = nil   // ✅ 強制釋放
            isStopping = true
            return false

        case .cancelled:
            logTo("listener 狀態 cancelled")
            listener.stateUpdateHandler = nil
            listener.cancel()
            self.listener = nil   // ✅ 強制釋放
            isStopping = true
            return false

        default:
            logTo("listener 狀態非 ready，清理中")
            listener.stateUpdateHandler = nil
            listener.cancel()
            self.listener = nil   // ✅ 強制釋放
            isStopping = true
            return false
        }
    }


    
    // MARK: - start
    func start(port: UInt16 = 9322) {

        guard !isRunning else {
            logTo("SocketServer already running")
            return
        }

        startActivityIdleTimer(reason: .noClientSinceStart)

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
                    self.listener = nil   // ✅ 強制清掉
                    self.scheduleRestart()

                case .cancelled:
                    self.logTo("Listener cancelled")
                    self.listener = nil   // ✅ 強制清掉

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
        if listener == nil {
            logTo("Listener missing, restarting")
            scheduleRestart(delay: 1.0)
        }
    }

    // MARK: - Handle New Connection
    private func handleNewConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        
        logTo("New connection added. Total connections: \(self.connections.count)")

        stopActivityIdleTimer()


        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }

            switch state {
            case .ready:

                if self.connections[ObjectIdentifier(connection)] != nil {
                    self.logTo("Connection ready: \(connection)")

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


        receiveBuffers[id] = Data()       // ✅ 為該連線創建專屬 buffer

        connection.start(queue: queue)
        receive(from: connection)
    }



    // MARK: - Receive Data
    private func receive(from connection: NWConnection) {
        let id = ObjectIdentifier(connection)

        guard connections[id] != nil else { return } // 連線已被移除，直接 return

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                var buffer = self.receiveBuffers[id] ?? Data()


                self.resetIdleTimer(for: connection)
                if LPConfig.shared.SocketLog {
                    logger.debug("Socket received \(data.count) bytes")
                }

                buffer.append(data)

                // 🔑 與 ReplyKit Client 完全相同的拆包邏輯
                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[..<newlineIndex]


                    let removeCount = buffer.distance(
                        from: buffer.startIndex,
                        to: buffer.index(after: newlineIndex)
                    )

                    buffer.removeFirst(removeCount)

                    guard !lineData.isEmpty else { continue }

                    self.handleReceivedData(Data(lineData), from: connection)

                }

                self.receiveBuffers[id] = buffer

            }

            if let error = error {
                self.logTo("Receive error: \(error)")
                self.removeConnection(connection)
                return
            }

            if isComplete {
                // EOF 時可選擇處理殘留（通常不用）
                if let buffer = self.receiveBuffers[id], !buffer.isEmpty {
                    self.handleReceivedData(buffer, from: connection)
                }
                self.receiveBuffers[id] = nil
                self.removeConnection(connection)
                return
            }

            
            self.receive(from: connection)


        }
    }
    

    func debugRTMP() {
        let rtmpPayload: [String: Any] = GetRTMPConfig()
        
        queueSend(payload: rtmpPayload)

    }

    struct ChatBufferMessage: Identifiable {
        let id = UUID()
        let user: String
        let msg: String
        let img: String
    }

    private var messageBuffer: [ChatBufferMessage] = []

    private var messageTimer: DispatchSourceTimer?



    struct TypePayload: Codable {
        let type:String
    }
    struct StreamEnded: Codable {
        let Message:String
    }

    // 1️⃣ 定義 batch request 結構
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
    }
    struct SLogMessage:Codable {
        let title:String
        let message:String
    }
    struct UPSet:Codable {
        let key:String
        let ValueType:String
    }

    struct AudioLive:Codable {
        let appVol:Float
        let micVol:Float
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


        logTo(
            "取得聊天室訊息:\(user):\(msg) Img:\(String(describing: img)) GIFT:\(String(describing: giftImg)) isMain:\(isMain)"
        )


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
            "isOringinAudio":userDefaults?.bool(forKey:"isOringinAudio") ?? true,
            "allowFrameReordering": userDefaults?.bool(forKey:"allowFrameReordering") ?? true,
            "h264level": userDefaults?
                .string(forKey: "h264level") ?? "AutoHigh",
            "BitRateMode": userDefaults?
                .integer(forKey: "BitRateMode") ?? 0,

            "videoBuffer": userDefaults?
                .integer(forKey: "BufferCount") ?? 5,

            "useBic": userDefaults?
                .bool(forKey: "useBic") ?? false,


            "dstW": userDefaults?.integer(forKey: "dstW") ?? 0,
            "dstH": userDefaults?.integer(forKey: "dstH") ?? 0,

            "odstW": userDefaults?.integer(forKey: "odstW") ?? 0,
            "odstH": userDefaults?.integer(forKey: "odstH") ?? 0,



            "Rotate": userDefaults?.integer(forKey: "Rotate") ?? 90 ,
            
            "RotateOriginal":userDefaults?.bool(forKey: "RotateOriginal") ?? false ,
            
            "enableEchoFix" : userDefaults?.bool(forKey: "enableEchoFix") ?? false,
            "enableNoiseFix": userDefaults?.bool(forKey: "enableNoiseFix") ?? false,
            "enableAGCFix" : userDefaults?.bool(forKey: "enableAGCFix") ?? false,
            


            "appVolume": userDefaults?
                .double(forKey: "appVolume") ?? 1.0,
            "micVolume": userDefaults?
                .double(forKey: "micVolume") ?? 1.0,

            "appVolumeAdd": userDefaults?
                .double(forKey: "appAddVolume") ?? 1.0,
            "micVolumeAdd": userDefaults?
                .double(forKey: "micAddVolume") ?? 1.0,



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



        ]

        logTo("RTMP DebugLogConfig[Socket]\(payload)")

        return payload

    }

    private func handleReceivedData(_ data: Data, from connection: NWConnection) {


        do {
            let decoder = JSONDecoder()
            
            // 先只 decode type
            let base = try decoder.decode(TypePayload.self, from: data)
            
            
            switch base.type {

            case "heartbeat":
                sendlog(message: "收到Socket心跳維持連線")

                break

            case "StreamStarting":
                sendlog(message: "直播開始")
                StreamStarting()

                break

            case "Ended":
                let dict = try decoder.decode(StreamEnded.self,
                    from: data
                )
                let MES = dict.Message

                sendlog(message: "直播已結束: \(MES)")

                if MES != "StreamEnded" {
                    StreamStatusChanged(isLive: false, message: MES)
                } else {
                    StreamStatusChanged(isLive: false)
                }

                break

            case "StreamMessage":

                // 假設你解析 JSON 得到 resultValue
                let dict = try decoder.decode(ChatMessage.self,
                    from: data
                )

                let user = dict.user
                let msg = dict.message



                let img : String? = dict.img
                let giftImg: String? = dict.giftImg
                let isMain: Bool = dict.isMain ?? true
                let userNum: Int? = dict.userNum
                let userList: [String]? = dict.userList

                updateAudienceInfo(
                    userNum: userNum,
                    userList: userList
                )


                guard !user.isEmpty, !msg.isEmpty else {
                    logTo("訊息是空的 不需要更新子母_StreamMessage")
                    return
                }


                renderChatMessage(
                    user: user,
                    msg: msg,
                    img: img,
                    giftImg: giftImg,
                    isMain: isMain
                )

                Task { @MainActor in
                    TTSService.shared.speakStreamMessage(
                        user: user,
                        message: msg,
                        isMain:isMain
                    )
                }

                break



                
                
            case "UPSet":

                // 假設你解析 JSON 得到 resultValue
                let dict = try decoder.decode(
                    UPSet.self,
                    from: data
                )

                let key = dict.key
                let VType = dict.ValueType

                
                var res : Any?
                
                switch VType {
                    
                case "String":
                    res = userDefaults?.string(forKey: key)
                case "Bool":
                    res = userDefaults?.bool(forKey: key)

                case "Double":
                    res =  userDefaults?.double(forKey: key)
                case "Int":
                    res =  userDefaults?.integer(forKey: key)
                    
                case "Float":
                    res =  userDefaults?.float(forKey: key)
                    
                default:
                    logTo("Unknow?")
                    return
                }
                
                
                guard let result = res else {
                    logTo("Value for key \(key) is nil")

                    let payload: [String: Any] = [

                        "type": "UPSet",
                        "key": key,
                        "value": "\(key) is Nil"
                    ]

                    sendTo(connection, payload: payload) // ← 只回應發送請求的 client

                    return
                }
                
                
                let payload: [String: Any] = [
                    
                    "type": "UPSet",
                    "key": key,
                    "value": result
                ]

                sendTo(connection, payload: payload) // ← 只回應發送請求的 client

                break


            case "batch":

                let json = try JSONSerialization.jsonObject(with: data)

                sendlog(message: "liveAppBactch Raw:\n\(json)")
                // 先解析 requests 陣列

                let dict = try decoder.decode(BatchRequest.self,
                    from: data
                )


                let requests = dict.requests

                
                sendlog(message: "liveAppBactch Req:\n\(requests)")

                let data = dict.data
                sendlog(message: "liveAppBactch Req:\n\(String(describing:data))")
                

                var responses: [[String: Any]] = []

                for req in requests {
                    switch req {
                    case "requestRTMP":
                        let rtmpPayload: [String: Any] = GetRTMPConfig()

                        responses.append(rtmpPayload)

                        break

                    case "logConfig":
                        let logPayload: [String: Any] = GetLogConfig()
                        responses.append(logPayload)
                        break

                    case "log":
                        

                        // 判斷 data 是否存在
                        if let data = data {
                            // 遍歷所有 key/value
                            for (key, value) in data {
                                logTo(String(describing: value), title: String(describing: key))
                            }
                        } else {

                            logTo("data 為 nil")

                        }

                        break



                    default:
                        break
                    }
                }

                let lastPayload: [String: Any] = [
                    "type": "BatchEnded"
                ]

                responses.append(lastPayload)


                // 將 responses 逐條發送給客戶端
                for (index, resp) in responses.enumerated() {

                    // 先發送給客戶端
                    sendTo(connection, payload: resp) // ← 只回應發送請求的 client


                    // 只對第一個元素做檢查
                    if index == 0, let type = resp["type"] as? String, type == "RTMP" {

                        // 複製 payload 並做修改
                        var logResp = resp
                        if let rtmpKey = logResp["rtmpKey"] as? String {
                            logResp["rtmpKey"] = fixlogSafeKey(rtmpKey)  // 你的自訂修改函數
                        }

                        // 打印日誌
                        sendlog(message: "RESBatch-RTMP->\n\(logResp)")
                    } else {
                        // 如果不是第一個或不是 RTMP，正常打印或不打印
                        sendlog(message: "RESBatch->\n\(resp)")
                    }
                }

                break




            case "logConfig":

                let payload: [String: Any] = GetLogConfig()

                sendTo(connection, payload: payload) // ← 只回應發送請求的 client
                break



            case "requestRTMP":

                let payload: [String: Any] = GetRTMPConfig()

                sendTo(connection, payload: payload) // ← 只回應發送請求的 client
                break



            case "requestSettings":
                logTo("棄用Sync UserDefaults to client 該項目不使用")
                break


            case "audioLive":
                // 假設你解析 JSON 得到 resultValue
                let dict = try decoder.decode(
                    AudioLive.self,
                    from: data
                )

                let AppVol = dict.appVol
                let MicVol = dict.micVol

                LiveVolumeModel.shared.updateVolumes(mic: MicVol, app: AppVol)


            case "settings":

                // 假設你解析 JSON 得到 resultValue
                let dict = try decoder.decode(
                    [String: JSONValue].self,
                    from: data
                )


                if let key = dict["key"]?.rawValue as? String, let valueAny = dict["value"]?.rawValue {
                    let safeValue: Any = safeJSONValue(valueAny) // 明確 Any
                    let safeValueStr = String(describing: safeValue)
                    logTo("Updated UserDefaults: \(key) = \(safeValueStr)")
                    
                    userDefaults?.set(valueAny, forKey: key) // 用原值存 UserDefaults
                    
                }

                break
                
            case "log":
                // 假設你解析 JSON 得到 resultValue
                let dict = try decoder.decode(SLogMessage.self,
                    from: data
                )

                let title = dict.title
                let message = dict.message

                receiveSocketLog(title: title, message: message)

                break
                

            default:
                logTo("Unknown message type: \(base.type)")
                break

            }
            
        }  catch {

            removeConnection(connection)
            logTo("[Socket]Decode failed ❌ \(error)")

        }
        
    }


    private var sendQueues: [ObjectIdentifier: [[String: Any]]] = [:]
    private var sendingFlags: [ObjectIdentifier: Bool] = [:]


    // MARK: 群播
    func queueSend(payload: [String: Any]) {
        for conn in connections.values {
            enqueue(payload, to: conn)
        }
    }

    private func enqueue(_ payload: [String: Any], to conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        queue.async {
            var queue = self.sendQueues[id] ?? []
            queue.append(payload)
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

            let payload = queue.removeFirst()
            self.sendQueues[id] = queue

            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
                self.sendNextPayload(for: conn) // 跳過錯誤 payload
                return
            }

            var dataWithNewline = data
            dataWithNewline.append(0x0A)

            self.resetIdleTimer(for: conn)


            // ⚠️ 啟動 watchdog timer
            let sendTimeout: DispatchWorkItem = DispatchWorkItem { [weak self, weak conn] in

                guard let self, let conn else { return }
                self.logTo("Send timeout, removing connection")
                self.removeConnection(conn)
            }

            self.queue.asyncAfter(deadline: .now() + 10, execute: sendTimeout)

            conn.send(content: dataWithNewline, completion: .contentProcessed { [weak self] error in

                sendTimeout.cancel() // 成功回來就取消 watchdog

                guard let self = self else { return }


                if let error {
                    self.removeConnection(conn)
                    self.logTo("Send error: \(error)")
                    return
                }

                self.sendNextPayload(for: conn) // 完成後再發下一個
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
            sendTo(conn, payload: payload) // ← 只回應發送請求的 client
        } else {

            logTo("廣播給所有已連線")
            queueSend(payload: payload)
        }


        }


    // MARK: 一對一
    private func sendTo(_ connection: NWConnection, payload: [String: Any]) {
        let id = ObjectIdentifier(connection)
        queue.async {
            var queue = self.sendQueues[id] ?? []
            queue.append(payload)
            self.sendQueues[id] = queue

            if self.sendingFlags[id] != true {
                self.sendingFlags[id] = true
                self.sendNextPayload(for: connection)
            }
        }
    }


    // MARK: - Connection Cleanup
    private func removeConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)

        guard connections[id] != nil else { return } // 已被移除

        idleTimers[id]?.cancel()
        idleTimers[id] = nil

        connection.stateUpdateHandler = nil
        connection.cancel()

        connections[id] = nil
        receiveBuffers[id] = nil
        sendQueues[id] = nil
        sendingFlags[id] = nil

        if connections.isEmpty {
            startActivityIdleTimer()
            self.logTo("已經沒有連線 啟動活動idleTimer")
        }

        

        logTo("Connection removed. Remaining: \(self.connections.count)")


    }

    func stop() {
        isStopping = true

        stopActivityIdleTimer()
        stopInternal()
    }


    func stopInternal() {


        for (_, conn) in connections {
            conn.stateUpdateHandler = nil
            conn.cancel()
        }

        listener?.stateUpdateHandler = nil
        listener?.cancel()

        listener = nil



        idleTimers.values.forEach { $0.cancel() }
        idleTimers.removeAll()




        connections.removeAll()
        receiveBuffers.removeAll()  // ✅ 同時清理所有 buffer

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

    // 保留前 (replaceCount - 2) 個字，再補 "00"
    if replaceCount > 2 {
        let startOfReplace = g.index(g.endIndex, offsetBy: -replaceCount)
        let midEnd = g.index(g.endIndex, offsetBy: -2)
        let middle = g[startOfReplace..<midEnd]
        g = prefix + middle + "00"
    } else {
        // 如果總長小於等於2，就全部換成0
        g = String(repeating: "0", count: g.count)
    }

    return g
}







