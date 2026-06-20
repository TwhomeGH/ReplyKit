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

    var onSocketReady: (() -> Void)?

    private var connection: NWConnection?

    private var readyContinuation: CheckedContinuation<Bool, Never>?

    private let queue = DispatchQueue(label: "SocketClientQueue")

    // 側載模式緩衝日誌：connection 尚未就緒時先暫存，ready 後自動發送
    private var pendingLogs: [(title: String, message: String)] = []

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
            if connection != nil {
                closeConnection()
            }

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

    func waitForReady(timeout: TimeInterval = 10.0) async -> Bool {
        if connection?.state == .ready { return true }
        return await withCheckedContinuation { cont in
            queue.async { [weak self] in
                guard let self = self else { cont.resume(returning: false); return }
                if self.connection?.state == .ready {
                    cont.resume(returning: true)
                } else {
                    self.readyContinuation = cont
                    // 安全 timeout，防止永遠等不到
                    self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        guard let self = self else { return }
                        if self.readyContinuation != nil {
                            self.readyContinuation = nil
                            cont.resume(returning: false)
                        }
                    }
                }
            }
        }
    }

    func closeConnection() {

        isConnection = false
        isProcessingBatch = false
        isReconnecting = false

        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil

        readyContinuation?.resume(returning: false)
        readyContinuation = nil

        // 取消所有 pending continuation 避免洩漏（同步執行，避免死鎖）
        rtmpContinuation?.resume(returning: false)
        rtmpContinuation = nil
        logContinuation?.resume(returning: false)
        logContinuation = nil
        rtmpBatchContinuation?.resume(returning: false)
        rtmpBatchContinuation = nil
        Task { await continuationStore.cancelAll() }

        stopHeartbeat()
        stopReceiveLoop()

        receiveBuffer.removeAll()  // ✅ 清空累積 buffer

        //stopObservingLocalChanges()
        self.logTo("SocketClient connection closed")


    }


    func start() {


        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
             case .ready:
                logTo("SocketClient connected")
                isConnection = true
                reconnectAttempt = 0
                circuitBreakerFailCount = 0
                circuitBreakerOpen = false
                if self.socketState.canTransition(to: .connected) {
                    self.socketState = .connected
                }
                sendReconnectStatus(.success)

                self.queue.async {
                    self.readyContinuation?.resume(returning: true)
                    self.readyContinuation = nil
                }

                startHearbeat()
                flushPendingLogs()
                sendLog(message:"Socket連接成功 擴展端通信")

                self.onSocketReady?()

                self.startReceiveLoop()
             case .failed(let error):
                logTo("SocketClient failed: \(String(describing: error))")
                self.queue.async {
                    self.readyContinuation?.resume(returning: false)
                    self.readyContinuation = nil
                }
                connection?.cancel()
                connection = nil
                isConnection = false
                if self.socketState.canTransition(to: .disconnected) {
                    self.socketState = .disconnected
                }

                // Circuit breaker: track consecutive failures
                self.circuitBreakerFailCount += 1
                if self.circuitBreakerFailCount >= self.circuitBreakerThreshold {
                    self.circuitBreakerOpen = true
                    self.logTo("🔒 電路斷路器開啟，冷卻 \(Int(self.circuitBreakerCooldown))s")
                    self.sendReconnectStatus(.exhausted)
                    self.queue.asyncAfter(deadline: .now() + self.circuitBreakerCooldown) { [weak self] in
                        guard let self = self else { return }
                        self.circuitBreakerOpen = false
                        self.circuitBreakerFailCount = 0
                        self.logTo("🔓 電路斷路器關閉，恢復重連")
                        self.retry()
                    }
                    return
                }

                self.retry()
             case .cancelled:


                logTo("SocketClient cancelled")
                self.queue.async {
                    self.readyContinuation?.resume(returning: false)
                    self.readyContinuation = nil
                }
                connection = nil

                isConnection = false
                if self.socketState.canTransition(to: .disconnected) {
                    self.socketState = .disconnected
                }

                guard !self.circuitBreakerOpen else {
                    self.logTo("⚠️ 電路斷路器已開啟，取消重連")
                    return
                }
                self.retry()
            default:
                break
            }
        }
        
        connection?.start(queue: queue)
    }

    private var isReconnecting = false
    private var reconnectAttempt = 0
    private let maxReconnectAttempts = 10

    // MARK: - Circuit Breaker
    private var circuitBreakerOpen = false
    private var circuitBreakerFailCount = 0
    private let circuitBreakerThreshold = 5
    private let circuitBreakerCooldown: TimeInterval = 60
    private var circuitBreakerTimer: DispatchSourceTimer?

    // MARK: - Connection State Machine
    private enum SocketState {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case circuitBreakerOpen

        func canTransition(to newState: SocketState) -> Bool {
            switch (self, newState) {
            case (.disconnected, .connecting),
                 (.connecting, .connected),
                 (.connecting, .disconnected),
                 (.connected, .disconnected),
                 (.reconnecting, .connecting),
                 (.reconnecting, .disconnected),
                 (.disconnected, .circuitBreakerOpen),
                 (.circuitBreakerOpen, .connecting),
                 (_, .disconnected):
                return true
            default:
                return false
            }
        }
    }

    private var socketState: SocketState = .disconnected

    private func reconnectDelay() -> TimeInterval {
        let base = min(pow(2.0, Double(reconnectAttempt)), 30.0)
        let jitter = Double.random(in: 0...base * 0.5)
        return base + jitter
    }

    func retry() {
        queue.async {
            self.stopHeartbeat()
            if self.circuitBreakerOpen {
                self.logTo("⚠️ 電路斷路器已開啟，跳過重連")
                self.sendReconnectStatus(.exhausted)
                return
            }
            guard !self.isReconnecting else { return }
            guard self.socketState.canTransition(to: .reconnecting) else { return }
            self.socketState = .reconnecting
            self.isReconnecting = true
            self.reconnectAttempt += 1

            let delay: TimeInterval
            if self.reconnectAttempt > self.maxReconnectAttempts {
                self.logTo("Max reconnect attempts (\(self.maxReconnectAttempts)) reached, continuing with 30s interval")
                self.sendReconnectStatus(.exhausted)
                delay = 30.0
            } else {
                delay = self.reconnectDelay()
                self.logTo("Reconnect attempt \(self.reconnectAttempt)/\(self.maxReconnectAttempts) in \(String(format: "%.1f", delay))s")
                self.sendReconnectStatus(.attempting)
            }

            self.queue.asyncAfter(deadline: .now() + delay) {
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

    private enum ReconnectPhase {
        case attempting
        case success
        case failed
        case exhausted
    }

    private func sendReconnectStatus(_ phase: ReconnectPhase) {
        let status: String
        switch phase {
        case .attempting: status = "attempting"
        case .success: status = "success"
        case .failed: status = "failed"
        case .exhausted: status = "exhausted"
        }
        let payload: [String: Any] = [
            "type": "reconnectStatus",
            "status": status,
            "attempt": reconnectAttempt,
            "maxAttempts": maxReconnectAttempts
        ]
        sendPayload(payload)
    }



    // MARK: - 發送
    func requestAllSettings() {

        logTo("嘗試請求設定Socket")
        let payload: [String: Any] = ["type": "requestSettings"]
        sendPayload(payload)
    }

    func requestSet(for key: String, type: String) async throws -> Any? {

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

        // 等待連線 ready，避免發送失敗或 timeout
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

    // MARK: 負責發送當前音訊指標
    func sendAudioLive(appVol:Float = 1.0, micVol:Float = 1.0,persist:Bool = false) {
        let payload: [String: Any] = [
            "type": "audioLive",
            "appVol": appVol,
            "micVol": micVol,
            "persist":persist
        ]
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

    func sendLog(title: String = "ReplyKitE_Sokcet", message: String) {
        guard connection != nil else {
            // 側載模式：connection 尚未就緒，先暫存，ready 後自動發送
            pendingLogs.append((title, message))
            return
        }
        let payload: [String: Any] = [
            "type": "log",
            "title": title,
            "message": message
        ]
        sendPayload(payload)
    }

    private func flushPendingLogs() {
        let logs = pendingLogs
        pendingLogs.removeAll()
        for log in logs {
            let payload: [String: Any] = [
                "type": "log",
                "title": log.title,
                "message": log.message
            ]
            sendPayload(payload)
        }
    }

    func logTo(_ message:String,flush:Bool = false){

        logger.debug("SocketDebug:\(message.count, privacy: .public) chars")

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
            self.isProcessingBatch = false
            cont.resume(returning: false)
        }
    }

    func cancelPendingRTMPBatch() {
        queue.async {
            guard let cont = self.rtmpBatchContinuation else { return }
            self.logTo("取消Batch請求")
            self.rtmpBatchContinuation = nil
            self.isProcessingBatch = false
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

        let sendTimeout = DispatchWorkItem { [weak self] in
            self?.logTo("Send timeout, triggering reconnect")
            self?.connection?.cancel()
            self?.connection = nil
            self?.retry()
        }
        queue.asyncAfter(deadline: .now() + 10, execute: sendTimeout)

        con.send(content: data, completion: .contentProcessed({ error in
            sendTimeout.cancel()
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
        var logRES: [String] = []

        logRES.append("[Get]RTMP:\(c.rtmpURL):\(fixlogSafeKey(c.rtmpKey))")

        logRES.append("[Get]Bit:\(c.BitRate):\(c.ChangeBit) 低延遲模式:\(c.isLowLatencyRateControlEnabled) useBic:\(c.useBic)")

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
            useBic: c.useBic,
            Rotate: c.Rotate,
            RotateOriginal: c.RotateOriginal,
            ADWidth: c.dstW,
            ADHeight: c.dstH,
            ODWidth: c.odstW,
            ODHeight: c.odstH,
            KeyFrameInterval: c.KeyFrameInterval
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
                    return
                }
                self.rtmpBatchContinuation = nil
                self.isProcessingBatch = false
                updateLogFixState()
                updateONLogFixState()
                cont.resume(returning: true)

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

            case "logConfig":
                if let env = try? decoder.decode(LogConfig.self, from: data) {
                    RPConfig.shared.logMode = env.logMode
                    RPConfig.shared.logURL = env.logURL
                    RPConfig.shared.onLogPage = env.onlogPage
                    RPConfig.shared.onAudioPage = env.onAudioPage
                    RPConfig.shared.enableLog = env.enableLog
                    RPConfig.shared.enableSocketLog = env.enableSocketLog
                    RPConfig.shared.enableTimeDebug = env.enableTimeDebug
                    RPConfig.shared.applyLogMode()
                    self.logTo("[Get]logMode:\(env.logMode) logURL:\(env.logURL) SocketLog:\(env.enableSocketLog) TimeDebug:\(env.enableTimeDebug)")
                    self.logTo("[Get]onLog:\(env.onlogPage) onAudio:\(env.onAudioPage) EnableLog:\(env.enableLog)")
                    if !self.isProcessingBatch {
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

            case "RTMP":
                if let env = try? decoder.decode(RTMPConfig.self, from: data) {
                    applyRTMP(env)
                } else {
                    logTo("[Socket] log decode failed")
                    if !self.isProcessingBatch {
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
        guard let self = self else { return }
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
                    self.retry()
                    return
                }

                self.processReceiveBuffer()
            }

            if let error = result.error {
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

            if result.isComplete, !self.receiveBuffer.isEmpty {
                self.processReceiveBuffer()
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

