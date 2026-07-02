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

        func cancelAll() {
            for (_, cont) in store {
                cont.resume(returning: nil)
            }
            store.removeAll()
        }
    }

    private let continuationStore = ContinuationStore()


    private var rtmpBatchContinuation: CheckedContinuation<Bool, Error>?

    private var rtmpContinuation: CheckedContinuation<Bool, Error>?

    private var logContinuation: CheckedContinuation<Bool, Error>?


    private var isConnection: Bool = false



    private var connection: NWConnection?

    private var readyContinuation: CheckedContinuation<Bool, Never>?

    private let queue = DispatchQueue(label: "SocketClientQueue")



    // MARK: - Batch Log Transport
    private var pendingBatchEntries: [String] = []
    private let maxBatchEntries = 50
    private let maxBatchBytes = 4096
    private var inFlightBatches = 0
    private let maxInflightBatches = 3
    private var batchTimer: DispatchSourceTimer?





    // 避免循環更新 UserDefaults
    private var isProcessingRemoteUpdate = false

    init() {
        
    }
    deinit {
        closeConnection()
    }

    
    // MARK: - 連線初始化
    func connect(host: String = "localhost" , port: UInt16 = 9322) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self._connect(host: host, port: port)
        }
    }

    private func _connect(host: String, port: UInt16) {
        dispatchPrecondition(condition: .onQueue(queue))

        if let conn = connection {
            switch conn.state {
            case .ready, .preparing, .waiting:
                return
            default:
                _closeConnection()
            }
        }

        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        start()

        isConnection = false
        isProcessingBatch = false

    }

    func waitForReady(timeout: TimeInterval = 10.0) async -> Bool {
        let deadline = DispatchTime.now() + timeout
        repeat {
            switch connection?.state {
            case .ready: return true
            case .failed, .cancelled: return false
            case .none, .preparing, .waiting: break
            default: break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        } while DispatchTime.now() < deadline
        return false
    }

    func closeConnection() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self._closeConnection()
        }
    }

    private func _closeConnection() {
        dispatchPrecondition(condition: .onQueue(queue))

        isConnection = false
        isProcessingBatch = false

        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil

        readyContinuation?.resume(returning: false)
        readyContinuation = nil

        rtmpContinuation?.resume(returning: false)
        rtmpContinuation = nil
        logContinuation?.resume(returning: false)
        logContinuation = nil
        rtmpBatchContinuation?.resume(returning: false)
        rtmpBatchContinuation = nil
        Task { await continuationStore.cancelAll() }

        stopReceiveLoop()
        stopBatchTimer()

        receiveBuffer.removeAll()
        pendingBatchEntries.removeAll()
        inFlightBatches = 0

        self.logTo("SocketClient connection closed")

    }


    func start() {
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
             case .ready:
                logTo("SocketClient connected")
                isConnection = true
                readyContinuation?.resume(returning: true)
                readyContinuation = nil
                startReceiveLoop()
             case .failed(let error):
                logTo("SocketClient failed: \(String(describing: error))")
                readyContinuation?.resume(returning: false)
                readyContinuation = nil
                cleanupConnection()
             case .cancelled:
                logTo("SocketClient cancelled")
                readyContinuation?.resume(returning: false)
                readyContinuation = nil
                cleanupConnection()
            default:
                break
            }
        }

        connection?.start(queue: queue)
    }

    private func cleanupConnection() {
        isConnection = false
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
        stopReceiveLoop()
    }





    // MARK: - 發送
    func requestAllSettings() {

        logTo("嘗試請求設定Socket")
        let payload: [String: Any] = ["type": "requestSettings"]
        sendPayload(payload)
    }

    func requestSet(for key: String, type: String) async throws -> Any? {

        connect()
        guard await waitForReady() else {
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




    func requestRTMPKEYAndLog(timeout: TimeInterval = 15.0) async -> Bool {
        do {
            return try await withTimeout(timeout) {
                try await self._requestRTMPKEYAndLog()
            }
        } catch TimeoutError.timedOut {
            logger.debug("RTMPKEY timeout")
            cancelPendingRTMPBatch()
            return false
        } catch {
            logger.debug("RTMPKEY error: \(error)")
            cancelPendingRTMPBatch()

            return false
        }
    }

    private func _requestRTMPKEYAndLog() async throws -> Bool {

        // 自動連線（on-demand）
        connect()
        let ready = await waitForReady()
        guard ready else {
            throw TimeoutError.timedOut
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in

                    guard self.rtmpBatchContinuation == nil else {
                        cont.resume(returning: false) // 已有 pending request，直接返回
                        return
                    }

                    self.rtmpBatchContinuation = cont
                    self.isProcessingBatch = true

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

    func requestRTMPKEY(timeout: TimeInterval = 15.0) async -> Bool {
        do {
            return try await withTimeout(timeout) {
                try await self._requestRTMPKEY()
            }
        } catch TimeoutError.timedOut {
            logger.debug("RTMPKEY timeout")
            cancelPendingRTMP()
        
            return false
        } catch {
            logger.debug("RTMPKEY error: \(error)")
            cancelPendingRTMP()

            return false
        }
    }

    private func _requestRTMPKEY() async throws -> Bool {

        connect()
        let ready = await waitForReady()
        guard ready else { throw TimeoutError.timedOut }
   

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

    func requestLogConfig(timeout: TimeInterval = 15.0) async -> Bool {
        do {
            return try await withTimeout(timeout) {
                try await self._requestLogConfig()
            }
        } catch TimeoutError.timedOut {
            logger.debug("LogConfig timeout")
            cancelPendingLog()

            return false
        } catch {
            logger.debug("LogConfig error: \(error)")
            cancelPendingLog()
            return false
        }
    }

    func _requestLogConfig() async throws -> Bool {

        connect()
        let ready = await waitForReady()
        guard ready else { throw TimeoutError.timedOut }

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
            "Message": "StreamEnded"
        ]

        queue.async { [weak self] in
            guard let self = self else { return }

            self._connect(host: "localhost", port: 9322)

            let group = DispatchGroup()
            group.enter()

            self.sendPayload(payload) { _ in
                group.leave()
            }

            group.notify(queue: self.queue) {
                self._closeConnection()
            }
        }
    }

    // MARK: 負責發送當前音訊指標
    func sendAudioLive(appVol:Float = 1.0, micVol:Float = 1.0,persist:Bool = false) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.connection?.state != .ready {
                self._connect()
            }
            let payload: [String: Any] = [
                "type": "audioLive",
                "appVol": appVol,
                "micVol": micVol,
                "persist":persist
            ]
            self.sendPayload(payload)
        }
    }

    func sendSettings(key: String, value: Any) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.connection?.state != .ready {
                self._connect()
            }
            let payload: [String: Any] = [
                "type": "settings",
                "key": key,
                "value": self.safeJSONValue(value)
            ]
            self.sendPayload(payload)
        }
    }

    func sendLog(title: String = "ReplyKitE_Sokcet", message: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.connection?.state == .ready else {
                return
            }
            self._sendLogPayload(title: title, message: message)
        }
    }

    // MARK: - Batch Log Transport
    func sendLogBatch(entries: [String]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.pendingBatchEntries.append(contentsOf: entries)
            self.checkBatch()
        }
    }

    private func checkBatch() {
        let totalBytes = pendingBatchEntries.reduce(0) { $0 + $1.utf8.count }
        if pendingBatchEntries.count >= maxBatchEntries || totalBytes >= maxBatchBytes {
            flushBatch()
        }
        if pendingBatchEntries.isEmpty {
            stopBatchTimer()
        } else {
            startBatchTimer()
        }
    }

    private func flushBatch() {
        guard !pendingBatchEntries.isEmpty else { return }
        guard inFlightBatches < maxInflightBatches else {
            let dropCount = min(pendingBatchEntries.count, maxBatchEntries)
            pendingBatchEntries.removeFirst(dropCount)
            return
        }

        if connection?.state != .ready {
            _connect(host: "localhost", port: 9322)
            return
        }

        let entries = pendingBatchEntries
        pendingBatchEntries.removeAll()
        stopBatchTimer()
        _sendBatch(entries)
    }

    func forceFlushBatch() {
        queue.sync { [weak self] in
            guard let self = self else { return }
            guard !self.pendingBatchEntries.isEmpty else { return }
            let entries = self.pendingBatchEntries
            self.pendingBatchEntries.removeAll()
            self.stopBatchTimer()
            _connect(host: "localhost", port: 9322)
            let payload: [String: Any] = [
                "type": "logbatch",
                "entries": entries
            ]
            self.sendPayload(payload)
        }
    }

    private func _sendBatch(_ entries: [String]) {
        inFlightBatches += 1
        let payload: [String: Any] = [
            "type": "logbatch",
            "entries": entries
        ]
        sendPayload(payload) { [weak self] _ in
            guard let self = self else { return }
            self.queue.async {
                self.inFlightBatches -= 1
                self.checkBatch()
            }
        }
    }

    private func startBatchTimer() {
        guard batchTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.flushBatch()
        }
        timer.resume()
        batchTimer = timer
    }

    private func stopBatchTimer() {
        batchTimer?.cancel()
        batchTimer = nil
    }



    private let maxLogChunkBytes = 8192

    private func _sendLogPayload(title: String, message: String) {
        guard message.utf8.count > maxLogChunkBytes else {
            _sendSingleLog(title: title, message: message)
            return
        }
        var chunks: [String] = []
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        var current = ""
        for line in lines {
            let candidate = current.isEmpty ? String(line) : current + "\n" + line
            if candidate.utf8.count > maxLogChunkBytes && !current.isEmpty {
                chunks.append(current)
                current = String(line)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        for chunk in chunks {
            _sendSingleLog(title: title, message: chunk)
        }
    }

    private func _sendSingleLog(title: String, message: String) {
        let payload: [String: Any] = [
            "type": "log",
            "title": title,
            "message": message
        ]
        sendPayload(payload)
    }

    func logTo(_ message:String,flush:Bool = false){

        logger.debug("SocketDebug:\(message.count, privacy: .public) chars")

        sendlog(title:"ReplyKit_Socket",message: message,flush: flush)
    }






    func cancelPendingRTMP() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let cont = self.rtmpContinuation else { return }
            self.logTo("取消RTMP請求")
            self.rtmpContinuation = nil
            cont.resume(returning: false)
            self._closeConnection()
        }
    }

    func cancelPendingLog() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let cont = self.logContinuation else { return }
            self.logTo("取消LogConfig請求")
            self.logContinuation = nil
            self.isProcessingBatch = false
            cont.resume(returning: false)
            self._closeConnection()
        }
    }

    func cancelPendingRTMPBatch() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let cont = self.rtmpBatchContinuation else { return }
            self.logTo("取消Batch請求")
            self.rtmpBatchContinuation = nil
            self.isProcessingBatch = false
            cont.resume(returning: false)
            self._closeConnection()
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

    // MARK: 公開供外部發送自定義訊息
    func sendPayload(_ payload: [String: Any]) {
        sendPayload(payload, completion: nil)
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
        let useEnhancedRTMP: Bool?
        let isOringinAudio:Bool?

        let h264level: String
        let BitRateMode: Int
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
        let enableMetalAudio: Bool

        let KeyFrameInterval: Int?
        let enableRTMPLog: Bool?

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
        let enablePipelineLog:Bool
    }

    struct LogMessage: Codable {
        let message: String
    }


    private func applyRTMP(_ c: RTMPConfig) {
        var logRES: [String] = []

        logRES.append("[Get]RTMP:\(c.rtmpURL):\(fixlogSafeKey(c.rtmpKey))")

        logRES.append("[Get]Bit:\(c.BitRate):\(c.ChangeBit) 低延遲模式:\(c.isLowLatencyRateControlEnabled) E-RTMP:\(c.useEnhancedRTMP ?? false) useBic:\(c.useBic)")

        logRES.append("[Get]H264:\(c.h264level) : \(c.dstW)x\(c.dstH) \(c.videoBuffer) 方向:\(c.Rotate) KF:\(c.KeyFrameInterval ?? -1)")

        logRES.append("[Get]OutDraw:\(c.odstW)x\(c.odstH) RotateOriginal:\(c.RotateOriginal)")

        RPConfig.shared.updateState(
            RTMPURL: c.rtmpURL,
            RTMPKey: c.rtmpKey,
            h264level: c.h264level,
            BitRateMode: c.BitRateMode,
            BufferCount: c.videoBuffer,
            BitRate: c.BitRate,
            ChangeBit: c.ChangeBit,
            isLowLatencyRateControlEnabled: c.isLowLatencyRateControlEnabled,
            useEnhancedRTMP: c.useEnhancedRTMP,
            useBic: c.useBic,
            Rotate: c.Rotate,
            RotateOriginal: c.RotateOriginal,
            ADWidth: c.dstW,
            ADHeight: c.dstH,
            ODWidth: c.odstW,
            ODHeight: c.odstH,
            KeyFrameInterval: c.KeyFrameInterval,
            enableRTMPLog: c.enableRTMPLog
        )

        RPConfig.shared.updateAudio(
            isOringinAudio: c.isOringinAudio,
            AppVolume: c.appVolume,
            MicVolume: c.micVolume,
            AppVolumeAdd: c.appVolumeAdd,
            MicVolumeAdd: c.micVolumeAdd,
            enableNoiseFix: c.enableNoiseFix,
            enableEchoFix: c.enableEchoFix,
            enableAGCFix: c.enableAGCFix,
            enableMetalAudio: c.enableMetalAudio
        )

        logRES.append("[Get]RTMPLog:\(c.enableRTMPLog ?? false)")
        logRES.append("[Get]Audio App:\(c.appVolume) Mic:\(c.micVolume) AppAdd:\(c.appVolumeAdd) MicAdd:\(c.micVolumeAdd)")
        logRES.append("[Get]Audio 降噪處理:\(c.enableNoiseFix) 回音處理:\(c.enableEchoFix) 自動增益:\(c.enableAGCFix) Metal:\(c.enableMetalAudio) ")

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("VideoReconfig" as CFString),
            nil, nil, true
        )

        self.logTo(logRES.joined(separator: "\n"))

        if !self.isProcessingBatch {
            guard let cont = self.rtmpContinuation else {
                self.logTo("[RTMP] no pending continuation, ignore")
                return
            }
            self.rtmpContinuation = nil
            cont.resume(returning: true)
            self._closeConnection()
        }
    }

    private var receiveBuffer = Data()

    private static let maxBufferSize = 1_048_576

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
        if RPConfig.shared.enableSocketLog {
            logger.debug("Receive JSON packet \(data.count, privacy: .public) bytes")
        }

        do {
            let json = try JSONSerialization.jsonObject(with: data)

            if let array = json as? [[String: Any]] {
                for item in array {
                    if let itemData = try? JSONSerialization.data(withJSONObject: item, options: []) {
                        handleSingleJSON(itemData)
                    }
                }
            } else if json is [String: Any] {
                handleSingleJSON(data)
            } else {
                logTo("[Socket] Unknown JSON format")
            }
        } catch {
            logTo("[Socket] JSON decode failed: \(error)")
        }
    }

    private static let parsingQueue = DispatchQueue(
        label: "SocketClientParsingQueue",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private func handleSingleJSON(_ data: Data) {
        SocketClient.parsingQueue.async { [weak self] in
            guard let self = self else { return }

            let base: TypePayload
            do {
                base = try JSONDecoder().decode(TypePayload.self, from: data)
            } catch {
                self.logTo("[Socket]Decode failed ❌ \(error)")
                return
            }

            self.queue.async { [data] in
                self.handleSingleJSONOnQueue(data: data, type: base.type)
            }
        }
    }

    let decoder = JSONDecoder()

    private func handleSingleJSONOnQueue(data: Data, type: String) {
        self.isProcessingRemoteUpdate = true
        defer { self.isProcessingRemoteUpdate = false }

            
            

            switch type {

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
                    self._closeConnection()
                    return
                }
                self.rtmpBatchContinuation = nil
                self.isProcessingBatch = false
                updateLogFixState()
                updateONLogFixState()
                cont.resume(returning: true)
                self._closeConnection()

            case "UPSet":
                logger.debug("DATA:\(data, privacy: .public)")
                logTo("UPSet結果得到了！\n\(data)")
                if let resultValue = try? decoder.decode([String: JSONValue].self, from: data),
                   let key = resultValue["key"]?.rawValue as? String,
                   let rawValue = resultValue["value"]?.rawValue {
                   let safeValue: Any? = {
                         if rawValue is NSNull { return nil }
                         return rawValue
                   }()

                    logTo("UPGet -> \(String(describing:key)) \(String(describing: safeValue))")


                    Task {
                        if let cont = await self.continuationStore.take(for: key) {
                            cont.resume(returning: safeValue)
                        }
                    }
                }
                self._closeConnection()

            case "logConfig":
                if let env = try? decoder.decode(LogConfig.self, from: data) {
                    RPConfig.shared.logMode = env.logMode
                    RPConfig.shared.logURL = env.logURL
                    RPConfig.shared.onLogPage = env.onlogPage
                    RPConfig.shared.onAudioPage = env.onAudioPage
                    RPConfig.shared.enableLog = env.enableLog
                    RPConfig.shared.enableSocketLog = env.enableSocketLog
                    if RPConfig.isSideload {
                        RPConfig.shared.enableSocketLog = true
                    }
                    RPConfig.shared.enableTimeDebug = env.enableTimeDebug
                    RPConfig.shared.enablePipelineLog = env.enablePipelineLog
                    RPConfig.shared.applyLogMode()
                    self.logTo("[Get]logMode:\(env.logMode) logURL:\(env.logURL) SocketLog:\(RPConfig.shared.enableSocketLog) TimeDebug:\(env.enableTimeDebug)")
                    self.logTo("[Get]onLog:\(env.onlogPage) onAudio:\(env.onAudioPage) EnableLog:\(env.enableLog)")
                    if !self.isProcessingBatch {
                        guard let cont = self.logContinuation else {
                            self.logTo("[LogConfig] no pending continuation, ignore")
                            self._closeConnection()
                            return
                        }
                        self.logContinuation = nil
                        cont.resume(returning: true)
                        self._closeConnection()
                    }
                } else {
                    self.logTo("[Socket] logConfig decode failed")
                    if !self.isProcessingBatch {
                        guard let cont = self.logContinuation else {
                            self.logTo("[LogConfig] no pending continuation, ignore")
                            self._closeConnection()
                            return
                        }
                        self.logContinuation = nil
                        cont.resume(returning: false)
                        self._closeConnection()
                    }
                }

            case "RTMP":
                if let env = try? decoder.decode(RTMPConfig.self, from: data) {
                    applyRTMP(env)
                } else {
                    logTo("[Socket] log decode failed")
                    if !self.isProcessingBatch {
                        guard let cont = self.rtmpContinuation else {
                            self.logTo("[RTMP] no pending continuation, ignore")
                            self._closeConnection()
                            return
                        }
                        self.rtmpContinuation = nil
                        cont.resume(returning: true)
                        self._closeConnection()
                    }
                }

            case "log":
                if let env = try? decoder.decode(LogMessage.self, from: data) {
                    self.logTo("[Extension] Get \(env.message)")
                } else {
                    logTo("[Socket] log decode failed")
                }

            default:
                logTo("[Socket] Unknown type: \(type)")
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
    private var receiveTask: Task<Void, Never>?

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    private func stopReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = nil
    }

    private func runReceiveLoop() async {
        guard let con = self.connection else { return }
        let currentConnection = con

        while !Task.isCancelled {
            guard self.connection === currentConnection else { break }

            let result: (data: Data?, isComplete: Bool, error: NWError?)
            do {
                result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool, NWError?), Error>) in
                    guard self.connection === currentConnection else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    con.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                        if let error = error {
                            continuation.resume(returning: (data, isComplete, error))
                        } else {
                            continuation.resume(returning: (data, isComplete, nil))
                        }
                    }
                }
            } catch {
                break
            }

            if let data = result.data {
                if RPConfig.shared.enableSocketLog {
                    logger.debug("Socket received \(data.count, privacy: .public) bytes")
                }

                self.receiveBuffer.append(data)

                if self.receiveBuffer.count > SocketClient.maxBufferSize {
                    self.logTo("Buffer exceeded \(SocketClient.maxBufferSize) bytes, closing connection")
                    self.cleanupConnection()
                    return
                }

                self.processReceiveBuffer()
            }

            if let error = result.error {
                self.logTo("Socket receive error: \(error), closing connection")

                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("liveAPP.SocketRestart" as CFString),
                    nil,
                    nil,
                    true
                )

                self.cleanupConnection()
                return
            }

            if result.isComplete, !self.receiveBuffer.isEmpty {
                self.processReceiveBuffer()
            }
        }
    }

    // private var localChangesObserver: NSObjectProtocol?

    // MARK: - 監聽本地 UserDefaults 因為目前沒有需要主動推送的設定變更，但未來如果有需要，可以考慮加入這個功能
    // private func observeLocalChanges() {
    //     localChangesObserver = NotificationCenter.default.addObserver(
    //         forName: UserDefaults.didChangeNotification,
    //         object: nil,
    //         queue: .main
    //     ) { [weak self] _ in
    //         guard let self = self, !self.isProcessingRemoteUpdate else { return }
    //         let defaults = UserDefaults.standard
    //         for (key, value) in defaults.dictionaryRepresentation() {
    //             self.sendSettings(key: key, value: value)
    //         }
    //     }

    // }

    // private func stopObservingLocalChanges() {
    //     if let observer = localChangesObserver {
    //         NotificationCenter.default.removeObserver(observer)
    //         localChangesObserver = nil
    //     }
    // }

    // MARK: - 初次同步
    // private func sendInitialUserDefaults() {
    //     let defaults = UserDefaults.standard
    //     for (key, value) in defaults.dictionaryRepresentation() {
    //         sendSettings(key: key, value: value)
    //     }
    // }

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

