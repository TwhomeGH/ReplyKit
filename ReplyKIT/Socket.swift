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


enum TimeoutError: Error {
    case timedOut
}

func withTimeout<T>(
    _ seconds: TimeInterval,
    operation: @escaping () async throws -> T
) async throws -> T {

    try await withThrowingTaskGroup(of: T.self) { group in

        // 真正的 operation
        group.addTask {
            try await operation()
        }

        // timeout watchdog
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError.timedOut
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}


class SocketClient : @unchecked Sendable {

    static let shared = SocketClient()

    private var isProcessingBatch = false


    actor ContinuationStore {
        private var store: [String: CheckedContinuation<Any?, Error>] = [:]

        func insert(_ cont: CheckedContinuation<Any?, Error>, for key: String) -> Bool {
            if store[key] != nil { return false }
            store[key] = cont
            return true
        }

        func take(for key: String) -> CheckedContinuation<Any?, Error>? {
            return store.removeValue(forKey: key)
        }
    }

    private let continuationStore = ContinuationStore()


    private var rtmpBatchContinuation: CheckedContinuation<Bool, Error>?

    private var rtmpContinuation: CheckedContinuation<Bool, Error>?

    private var logContinuation: CheckedContinuation<Bool, Error>?


    private var isConnection: Bool = false

    private var connection: NWConnection?

    private let queue = DispatchQueue(label: "SocketClientQueue")

    // 心跳相關 專用 Queue 和 Timer
    private let queueHeart = DispatchQueue(label: "SocketClientQueueHeartbeat")

    private var HeartbeatTimer: DispatchSourceTimer?

    func startHearbeat(interval: TimeInterval = 50.0) {
        guard HeartbeatTimer == nil else {
            sendLog(message: "已啟用心跳!")
            return
        }

        logTo("啟用Socket心跳")

        let timer = DispatchSource.makeTimerSource(queue: queueHeart)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(10)
        )

        timer.setEventHandler { [weak self] in
            self?.sendHeartbeat()
        }

        timer.resume()
        self.HeartbeatTimer = timer
    }

    func stopHeartbeat() {
        HeartbeatTimer?.cancel()
        HeartbeatTimer = nil

        logTo("關閉Socket心跳")
    }


    private func sendHeartbeat() {
        let payload: [String: Any] = ["type": "heartbeat"]
        sendPayload(payload)
        logTo("ReplyKit Socket保活心跳訊息")
    }



    // 避免循環更新 UserDefaults
    private var isProcessingRemoteUpdate = false

    init() {
        
    }
    deinit {
        closeConnection()
    }

    
    // MARK: - 連線初始化
    func setupConnection(host: String = "localhost" , port: UInt16 = 9322) {
            connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            start()

            isConnection = false
            isProcessingBatch = false
            isReconnecting = false

    }

    func closeConnection() {

        isConnection = false
        isProcessingBatch = false
        isReconnecting = false

        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil

        stopHeartbeat()

        receiveBuffer.removeAll()  // ✅ 清空累積 buffer

        //stopObservingLocalChanges()
        self.logTo("SocketClient connection closed")

        
    }


    func start() {

        guard let con = connection else {
            return
        }

        con.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                logTo("SocketClient connected")
                isConnection = true

                startHearbeat()
                sendLog(message:"Socket連接成功 擴展端通信")
                

                

                self.receive()
            case .failed(let error):
                logTo("SocketClient failed: \(String(describing: error))")
                isConnection = false


                self.retry()
            case .cancelled:


                logTo("SocketClient cancelled")

                isConnection = false
                self.retry()
            default:
                break
            }
        }
        con.start(queue: queue)
    }

    private var isReconnecting = false

    func retry() {


        queue.async {
            self.stopHeartbeat()

            guard !self.isReconnecting else { return }   // ✅ 防止重入
            self.isReconnecting = true

            self.queue.asyncAfter(deadline: .now() + 2.0) {
                [weak self] in
                guard let self = self else { return }

                self.isReconnecting = false

                self.connection?.stateUpdateHandler = nil
                self.connection?.cancel()
                self.connection = nil

                self.receiveBuffer.removeAll()

                self.setupConnection()
            }
        }
        
    }



    // MARK: - 發送
    func requestAllSettings() {

        logTo("嘗試請求設定Socket")
        let payload: [String: Any] = ["type": "requestSettings"]
        sendPayload(payload)
    }

    func requestSet(for key: String, type: String) async throws -> Any? {

        guard let con = connection,con.state == .ready else {
            return nil
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in

            Task {
                let inserted = await continuationStore.insert(continuation, for: key)

                if !inserted {
                    continuation.resume(returning: nil)
                    return
                }


                let payload: [String: Any] = [
                    "type": "UPSet",
                    "key": key,
                    "ValueType": type
                ]
                self.sendPayload(payload)
            }



        }

    }

//    func requestSet(for key:String, type:String,completion: @escaping (Any?) -> Void) {
//
//
//        logTo("嘗試請求特定設定Socket")
//
//        let payload: [String: Any] = [
//            "type": "UPSet",
//            "key": key,
//            "ValueType":type
//        ]
//        sendPayload(payload)
//
//    }




    func requestRTMPKEYAndLog(timeout: TimeInterval = 5.0) async -> Bool {
        do {
            return try await withTimeout(timeout) {
                try await self._requestRTMPKEYAndLog()
            }
        } catch TimeoutError.timedOut {
            logger.debug("RTMPKEY timeout")
            return false
        } catch {
            logger.debug("RTMPKEY error: \(error)")

            return false
        }
    }

    private func _requestRTMPKEYAndLog() async throws -> Bool {


        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in

                    guard self.rtmpBatchContinuation == nil else {
                        cont.resume(returning: false) // 已有 pending request，直接返回
                        return
                    }

                    self.rtmpBatchContinuation = cont

                    let payload: [String: Any] = [
                        "type": "batch",
                        "requests": ["requestRTMP", "logConfig"]

                    ]
                    self.sendPayload(payload)


            }


    }



    // func requestRTMPKEYAndLog(timeout: TimeInterval = 5.0) async -> Bool {
    //     do {
    //         return try await withTimeout(timeout) {
    //             try await self._requestRTMPKEYAndLog()
    //         }
    //     } catch TimeoutError.timedOut {
    //         logger.debug("RTMPKEY timeout")
    //         return false
    //     } catch {
    //         logger.debug("RTMPKEY error: \(error)")

    //         return false
    //     }
    // }

    // private func _requestRTMPKEYAndLog() async throws -> Bool {


    //     return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in

    //                 guard self.rtmpBatchContinuation == nil else {
    //                     cont.resume(returning: false) // 已有 pending request，直接返回
    //                     return
    //                 }

    //                 self.rtmpBatchContinuation = cont

    //                 let payload: [String: Any] = [
    //                     "type": "batch",
    //                     "requests": ["requestRTMP", "logConfig"]

    //                 ]
    //                 self.sendPayload(payload)


    //         }


    // }


    // MARK: - 發送

    func requestRTMPKEY(timeout: TimeInterval = 5.5) async -> Bool {
        do {
            return try await withTimeout(timeout) {
                try await self._requestRTMPKEY()
            }
        } catch TimeoutError.timedOut {
            logger.debug("RTMPKEY timeout")
        
            return false
        } catch {
            logger.debug("RTMPKEY error: \(error)")

            return false
        }
    }

    private func _requestRTMPKEY() async throws -> Bool {


        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in

                    guard self.rtmpContinuation == nil else {
                        cont.resume(returning: false) // 已有 pending request，直接返回
                        return
                    }

                    self.rtmpContinuation = cont


                    let payload: [String: Any] = ["type": "requestRTMP"]
                    self.sendPayload(payload)

                    


            }


    }

    func requestLogConfig(timeout: TimeInterval = 5.5) async -> Bool {
        do {
            return try await withTimeout(timeout) {
                try await self._requestLogConfig()
            }
        } catch TimeoutError.timedOut {
            logger.debug("LogConfig timeout")

            return false
        } catch {
            logger.debug("LogConfig error: \(error)")
            return false
        }
    }

    func _requestLogConfig() async throws -> Bool {


        self.isProcessingBatch = true

        return try await withCheckedThrowingContinuation { cont in

                // 如果已經有 pending request，直接回 false
                guard self.logContinuation == nil else {
                    cont.resume(returning: false)
                    return
                }


                self.logContinuation = cont

                let payload: [String: Any] = ["type": "logConfig"]
                self.sendPayload(payload)






        }

    }




    func sendStreamEnd() {
        let payload: [String: Any] = [
            "type": "Ended",
            "Message": "直播結束"
        ]

        queue.async { [weak self] in
            guard let self = self else { return }

            let group = DispatchGroup()
            group.enter()

            self.sendPayload(payload) { _ in
                group.leave()
            }

            group.notify(queue: self.queue) {
                self.closeConnection()
            }
        }
    }

    func sendSettings(key: String, value: Any) {
        let payload: [String: Any] = [
            "type": "settings",
            "key": key,
            "value": safeJSONValue(value)
        ]
        sendPayload(payload)
    }

    func sendLog(title: String = "ReplyKitE_Sokcet", message: String) {
        guard connection != nil else {
            logger.debug("Socket可能沒上線!")
            return
        }
        let payload: [String: Any] = [
            "type": "log",
            "title": title,
            "message": message
        ]
        sendPayload(payload)
    }

    func logTo(_ message:String,flush:Bool = false){

        logger.debug("SocketDebug:\(message, privacy: .public)")

        sendlog(title:"ReplyKit_Socket",message: message,flush: flush)
    }






    func cancelPendingRTMP() {
        queue.async {
            guard let cont = self.rtmpContinuation else { return }
            self.logTo("取消RTMP請求")
            self.rtmpContinuation = nil
            cont.resume(returning: false)
        }
    }

    func cancelPendingLog() {
        queue.async {
            guard let cont = self.logContinuation else { return }
            self.logTo("取消LogConfig請求")
            self.logContinuation = nil
            cont.resume(returning: false)
        }
    }






    // MARK: CallBack Payload
    private func sendPayload(_ payload: [String: Any], completion: ((NWError?) -> Void)? = nil) {
        guard let con = connection else {
            logger.debug("Socket可能沒上線!")
            completion?(nil)
            return
        }
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            completion?(nil)
            return
        }
        data.append(0x0A)

        con.send(content: data, completion: .contentProcessed({ error in
            if let error = error {
                self.logTo("Socket Send error: \(error.localizedDescription)")
            }
            completion?(error)
        }))
    }

    // MARK: No CallBack Payload
    private func sendPayload(_ payload: [String: Any]) {
        guard let con = connection else {
            logger.debug("Socket可能沒上線!")

            return
        }
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
        data.append(0x0A) // '\n'
        
        con.send(content: data, completion: .contentProcessed({ error in
            if let error = error {
                self.logTo("Socket Send error: \(error.localizedDescription)")
                // 遇到 send error 可選擇重試或清理
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
        let isLowLatencyRateControlEnabled:Bool

        let h264level: String
        let videoBuffer: Int

        let useBic : Bool

        let dstW: Int
        let dstH: Int

        let odstW: Int
        let odstH: Int


        let Rotate: Int
        let RotateOriginal: Bool

        let enableEchoFix: Bool
        let enableNoiseFix: Bool
        let enableAGCFix: Bool

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
        let enableLog: Bool
        let enableSocketLog:Bool
        let enableTimeDebug:Bool
    }

    struct LogMessage: Codable {
        let message: String
    }


    private func applyRTMP(_ c: RTMPConfig) {

        queue.async {

            var logRES: [String] = [

            ]

            logRES.append("[Get]RTMP:\(c.rtmpURL):\(fixlogSafeKey(c.rtmpKey))")
            


            logRES.append("[Get]Bit:\(c.BitRate):\(c.ChangeBit) 低延遲模式:\(c.isLowLatencyRateControlEnabled) useBic:\(c.useBic)")


           

            logRES.append("[Get]H264:\(c.h264level) : \(c.dstW)x\(c.dstH) \(c.videoBuffer) 方向:\(c.Rotate)")


           

            logRES.append(
                "[Get]OutDraw:\(c.odstW)x\(c.odstH) RotateOriginal:\(c.RotateOriginal)"
            )



            RPConfig.shared.updateState(RTMPURL:c.rtmpURL,
                                        RTMPKey:c.rtmpKey,
                                        h264level:c.h264level,
                                        BufferCount:c.videoBuffer,
                                        BitRate:c.BitRate,
                                        ChangeBit:c.ChangeBit,
                                        isLowLatencyRateControlEnabled:c.isLowLatencyRateControlEnabled,
                                        useBic:c.useBic,
                                        
                                        Rotate:c.Rotate,
                                        RotateOriginal:c.RotateOriginal,
                                        ADWidth:c.dstW,
                                        ADHeight:c.dstH,
                                        ODwidth:c.odstW,
                                        ODHeight:c.odstH,
                                        AppVolume:c.appVolume,
                                        MicVolume:c.micVolume,
                                        AppVolumeAdd:c.appVolumeAdd,
                                        MicVolumeAdd:c.micVolumeAdd,
                                        enableNoiseFix:c.enableNoiseFix,
                                        enableEchoFix:c.enableEchoFix,
                                        enableAGCFix:c.enableAGCFix
                                        )



            logRES.append(
                "[Get]Audio App:\(c.appVolume) Mic:\(c.micVolume) AppAdd:\(c.appVolumeAdd) MicAdd:\(c.micVolumeAdd)"
            )
            logRES.append(
                "[Get]Audio 降噪處理:\(c.enableNoiseFix) 回音處理:\(c.enableEchoFix) 自動增益:\(c.enableAGCFix) "
            )

            

            self.logTo(logRES.joined(separator: "\n"))

            if !self.isProcessingBatch {
                // 單請求才 resume rtmpContinuation

                guard let cont = self.rtmpContinuation else {
                    self.logTo("[RTMP] no pending continuation, ignore")
                    return
                }

                self.rtmpContinuation = nil
                cont.resume(returning: true)
            }

        }


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
        // 先轉成 String
        guard let string = String(data: data, encoding: .utf8) else {
            logTo("[Socket] Invalid UTF8")
            return
        }

        // 按換行拆成多條 JSON
        let lines = string.split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines {
            guard let lineData = line.data(using: .utf8) else { continue }

            do {
                let json = try JSONSerialization.jsonObject(with: lineData)
                logger.debug("Revice Raw:\n\(json as! NSObject, privacy: .public)")

                if let array = json as? [[String: Any]] {
                    // 批量 JSON
                    for item in array {
                        if let itemData = try? JSONSerialization.data(withJSONObject: item, options: []) {
                            handleSingleJSON(itemData)
                        }
                    }
                } else if json is [String: Any] {
                    handleSingleJSON(lineData)
                } else {
                    logTo("[Socket] Unknown JSON format")
                }

            } catch {
                logTo("[Socket] JSON decode failed: \(error)")
            }
        }
    }

    private func handleSingleJSON(_ data: Data) {
        do {

            let decoder = JSONDecoder()

            // 先只 decode type
            let base = try decoder.decode(TypePayload.self, from: data)

            self.isProcessingRemoteUpdate = true
            defer { self.isProcessingRemoteUpdate = false }

            switch base.type {

            case "testRTMP":

                Task { @MainActor in

                    let rtmp = await self.requestRTMPKEY()
                    let log  = await self.requestLogConfig()

                    self.logTo("RTMP: \(rtmp) LogConfig: \(log)")

                }

            case "BatchEnded":
                self.logTo("Batch Get All Req")

                guard let cont = self.rtmpBatchContinuation else {
                    self.logTo("[rtmpBatch] no pending continuation, ignore")
                    return
                }
                self.rtmpBatchContinuation = nil
                self.isProcessingBatch = true
                updateLogFixState()
                updateONLogFixState()
                
                cont.resume(returning: true)




            case "UPSet":
                logger.debug("DATA:\(data, privacy: .public)")
                logTo("UPSet結果得到了！\n\(data)")
                // 假設你解析 JSON 得到 resultValue
                if let resultValue = try? decoder.decode(
                    [String: JSONValue].self,
                    from: data
                ),
                   let key = resultValue["key"]?.rawValue as? String,
                   let rawValue = resultValue["value"]?.rawValue {

                    // 將 Optional 或 NSNull 處理成 nil
                     let safeValue: Any? = {
                         if rawValue is NSNull { return nil }
                         return rawValue
                     }()


                    logger
                        .debug(
                            "UPSet key=\(key, privacy: .public) type=\(type(of: rawValue), privacy: .public) value=\(String(describing:rawValue), privacy: .public) SafeVal:\(String(describing:rawValue),privacy: .public)"
                        )

                    logTo(
                        "UPGet -> \(String(describing: safeValue)) \(String(describing: safeValue))"
                    )

                    Task {
                        if let cont = await continuationStore.take(for: key) {
                            cont.resume(returning: safeValue)
                        }
                    }



                }



            case "logConfig":

                queue.async {


                    if let env = try? decoder.decode(LogConfig.self, from: data) {

                        RPConfig.shared.logMode = env.logMode
                        RPConfig.shared.logURL = env.logURL

                        RPConfig.shared.onLogPage = env.onlogPage
                        RPConfig.shared.onAudioPage = env.onAudioPage
                        RPConfig.shared.enableLog = env.enableLog
                        RPConfig.shared.enableSocketLog = env.enableSocketLog
                        RPConfig.shared.enableTimeDebug = env.enableTimeDebug

                        RPConfig.shared.applyLogMode()

                        self.logTo(
                            "[Get]logMode:\(env.logMode) logURL:\(env.logURL) SocketLog:\(env.enableSocketLog) TimeDebug:\(env.enableTimeDebug)"
                        )
                        self.logTo(
                            "[Get]onLog:\(env.onlogPage) onAudio:\(env.onAudioPage) EnableLog:\(env.enableLog)"
                        )



                        if !self.isProcessingBatch {
                            // 單請求才 resume rtmpContinuation

                            guard let cont = self.logContinuation else {
                                self.logTo("[LogConfig] no pending continuation, ignore")
                                return
                            }

                            self.logContinuation = nil
                            cont.resume(returning: true)

                        }


                    } else {

                        self.logTo("[Socket] logConfig decode failed")


                        guard let cont = self.logContinuation else {
                            self.logTo("[LogConfig] no pending continuation, ignore")
                            return
                        }
                        
                        self.logContinuation = nil
                        cont.resume(returning: false)

                    }
                }


            case "RTMP":
                if let env = try? decoder.decode(RTMPConfig.self, from: data) {
                    applyRTMP(env)
                } else {
                    logTo("[Socket] log decode failed")

                    if !self.isProcessingBatch {
                        // 單請求才 resume rtmpContinuation

                        guard let cont = self.rtmpContinuation else {
                            self.logTo("[RTMP] no pending continuation, ignore")
                            return
                        }

                        self.rtmpContinuation = nil
                        cont.resume(returning: true)
                    }
                    
                }



            case "log":
                if let env = try? decoder.decode(LogMessage.self, from: data) {
                    self.logTo("[Extension] Get \(env.message)")
                } else {
                    logTo("[Socket] log decode failed")
                }



            default:
                logTo("[Socket] Unknown type: \(base.type)")
            }

        } catch {
            logTo("[Socket]Decode failed ❌ \(error)")

        }
    }

    private func processReceiveBuffer() {
        while true {
            guard let newlineIndex = receiveBuffer.firstIndex(of: 0x0A) else {
                break
            }

            // ① 拿出一行
            let lineData = receiveBuffer[..<newlineIndex]

            // ② 計算「實際要移除的元素數」
            let removeCount = receiveBuffer.distance(
                from: receiveBuffer.startIndex,
                to: receiveBuffer.index(after: newlineIndex)
            )

            // ③ 移除
            receiveBuffer.removeFirst(removeCount)

            // ④ 空行跳過
            guard !lineData.isEmpty else { continue }

            handleJSONPacket(Data(lineData))
        }
        
    }

    // MARK: - 接收資料
    private func receive() {
        guard let con = connection else { return }

        let currentConnection = con // 捕獲當下的 connection

        con.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            guard self.connection === currentConnection else { return }

            if let data = data {
                logTo("🔹 Received \(data.count) bytes: \(String(decoding: data, as: UTF8.self))")

                self.receiveBuffer.append(data)

                // 使用 processReceiveBuffer 處理所有可解析的 JSON
                self.processReceiveBuffer()

            }

            if let error = error {
                self.logTo("Socket receive error: \(error)")

                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("liveAPP.SocketRestart" as CFString),
                    nil,
                    nil,
                    true
                )

                self.retry()
                return
            }

            // EOF 時處理最後一筆資料（可能沒有換行符）
            if isComplete, !self.receiveBuffer.isEmpty {
                self.processReceiveBuffer()
            }

            self.receive() // 繼續接收
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
