import Foundation
import Network
import os


//let logger = Logger(subsystem: "nuclear.liveAPP", category: "SocketServer")

class SocketServer {

    // MARK: - Properties

    static let shared = try? SocketServer()


    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "SocketServerQueue")

    // MARK: - Init
    init(port: UInt16 = 9322) throws {
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        listener?.start(queue: queue)
        logTo("SocketServer started on port \(port)")
    }

    func logTo(_ mes:String){
        sendlog(message: "\(mes)")
    }

    // MARK: - Handle New Connection
    private func handleNewConnection(_ connection: NWConnection) {
        connections.append(connection)
        logTo(
                "New connection added. Total connections: \(self.connections.count)"
            )

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.logTo("Connection ready: \(String(describing: connection))")
                //self?.sendInitialUserDefaults(to: connection)
            case .failed(let error):
                self?.logTo("Connection failed: \(error.localizedDescription)")
                self?.removeConnection(connection)
            case .cancelled:
                self?.logTo("Connection cancelled")
                self?.removeConnection(connection)
            default:
                break
            }
        }

        connection.start(queue: queue)
        receive(from: connection)
    }

    private var receiveBuffer = Data()

    // MARK: - Receive Data
    private func receive(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }


            if let data = data, !data.isEmpty {
                // 1️⃣ 累積到 buffer
                self.receiveBuffer.append(data)

                // 2️⃣ 拆包，每個 \n 為一個完整 JSON
               while let range = self.receiveBuffer.firstRange(of: Data([0x0A])) {
                   let packet = self.receiveBuffer.subdata(in: 0..<range.lowerBound)
                   // 移除已處理的資料（包含 \n）
                   self.receiveBuffer.removeSubrange(0...range.lowerBound)

                   // 3️⃣ 處理單一 JSON packet
                   self.handleReceivedData(packet, from: connection)
               }

            }



            if isComplete || error != nil {
                self.removeConnection(connection)
            } else {
                self.receive(from: connection)
            }
        }
    }

    func debugRTMP() {
        let payload: [String: Any] = [
            "type": "RTMP",
            "rtmpURL": userDefaults?.string(forKey: "rtmpURL") ?? "rtmp://192.168.0.102/live",
            "rtmpKey": userDefaults?.string(forKey: "rtmpKey") ?? "test",
            "BitRate": userDefaults?.integer(forKey: "bitRate") ?? 3_900_000,
            "ChangeBit": userDefaults?.bool(forKey: "ChangeBit") ?? false,
            "h264level": userDefaults?
                .string(forKey: "h264level") ?? "AutoHigh",



            "dstW": userDefaults?.integer(forKey: "dstW") ?? 0,
            "dstH": userDefaults?.integer(forKey: "dstH") ?? 0,

            "appVolume": userDefaults?.float(forKey: "appVolume") ?? 1.0,
            "micVolume": userDefaults?.float(forKey: "micVolume") ?? 1.0,
            "appVolumeAdd": userDefaults?
                .double(forKey: "appAddVolume") ?? 1.0,
            "micVolumeAdd": userDefaults?
                .double(forKey: "micAddVoulme") ?? 1.0,



        ]
        sendToAll(payload: payload)

    }

    private func handleReceivedData(_ data: Data, from connection: NWConnection) {



        guard let dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let type = dict["type"] as? String else { return }

        switch type {

        case "logConfig":
            let payload: [String: Any] = [
                "type": "logConfig",
                "logMode": userDefaults?.integer(forKey: "logMode")
                ?? 1,

                "logURL": userDefaults?
                    .string(
                        forKey: "logURL"
                    ) ?? "http://192.168.0.242:3000/post",



                "onlogPage":userDefaults?.bool(forKey: "onlogPage")
                ?? false,
                "onAudioPage":userDefaults?.bool(forKey: "onAudioPage") ?? false,

                "enablelog":userDefaults?.bool(forKey: "Enablelog")
                ?? false
                ]

            sendToAll(payload: payload)

        case "requestRTMP":
            let payload: [String: Any] = [
                "type": "RTMP",
                "rtmpURL": userDefaults?.string(forKey: "rtmpURL") ?? "rtmp://192.168.0.102/live",
                "rtmpKey": userDefaults?.string(forKey: "rtmpKey") ?? "test",
                "BitRate": userDefaults?.integer(forKey: "bitRate") ?? 3_900_000,
                "ChangeBit": userDefaults?.bool(forKey: "ChangeBit") ?? false,
                "h264level": userDefaults?
                    .string(forKey: "h264level") ?? "AutoHigh",



                "dstW": userDefaults?.integer(forKey: "dstW") ?? 0,
                "dstH": userDefaults?.integer(forKey: "dstH") ?? 0,

                "appVolume": userDefaults?.float(forKey: "appVolume") ?? 1.0,
                "micVolume": userDefaults?.float(forKey: "micVolume") ?? 1.0,
                "appVolumeAdd": userDefaults?
                    .double(forKey: "appAddVolume") ?? 1.0,
                "micVolumeAdd": userDefaults?
                    .double(forKey: "micAddVolume") ?? 1.0,



            ]

            logTo("RTMP DebugAdd[Socket]\(payload)")
            sendToAll(payload: payload)

        case "requestSettings":
            logTo("Sync UserDefaults to client")
            sendInitialUserDefaults(to: connection)

        case "settings":
            if let key = dict["key"] as? String, let valueAny = dict["value"] {
                let safeValue: Any = safeJSONValue(valueAny) // 明確 Any
                let safeValueStr = String(describing: safeValue)
                logTo("Updated UserDefaults: \(key) = \(safeValueStr)")

                UserDefaults.standard.set(valueAny, forKey: key) // 用原值存 UserDefaults

                broadcast(key: key, value: safeValue) // 型別明確，不再報錯
            }

        case "log":
            if let message = dict["message"] as? String {
                appendLogToFile(message)
                logTo("Received log: \(message)")
            }

        default:
            logTo("Unknown message type: \(type)")
        }
    }

    // MARK: - Send Data
    private func sendToAll(payload: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }

        // ★ 關鍵：加換行符號當封包結尾
        data.append(0x0A) // '\n'


        for conn in connections {
            conn.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    self.logTo("Send error: \(error.localizedDescription)")
                }
            })
        }
    }

    func broadcast(type:String = "settings",key: String, value: Any) {
        var payload: [String: Any] = [
            "type": type,
            "key": key,
            "value": safeJSONValue(value)
        ]

        if type == "log" {
            payload["message"] = value
        }

        sendToAll(payload: payload)
    }

    func sendInitialUserDefaults(to connection: NWConnection? = nil) {
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        for (key, value) in defaults {
            let payload: [String: Any] = [
                "type": "settings",
                "key": key,
                "value": safeJSONValue(value)
            ]
            if let conn = connection {
                sendTo(conn, payload: payload)
            } else {
                sendToAll(payload: payload)
            }
        }
    }

    private func sendTo(_ connection: NWConnection, payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - Connection Cleanup
    private func removeConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = nil
        connection.cancel()
        if let index = connections.firstIndex(where: { $0 === connection }) {
            connections.remove(at: index)
        }
        logTo("Connection removed. Remaining: \(self.connections.count)")
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        for conn in connections {
            conn.stateUpdateHandler = nil
            conn.cancel()
        }
        connections.removeAll()
        logTo("SocketServer stopped")
    }

    deinit {
        stop()
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

    private func appendLogToFile(_ log: String) {
        let fileName = "extension.log"
        let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        guard let documentsURL = urls.first else { return }
        let fileURL = documentsURL.appendingPathComponent(fileName)

        if let data = (log + "\n").data(using: .utf8) {
            if FileManager.default.fileExists(atPath: fileURL.path),
               let fileHandle = try? FileHandle(forWritingTo: fileURL) {
                defer { fileHandle.closeFile() }
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}


//
//  CFMessagePortServer.swift
//  liveAPP
//
//  Created by user on 2025/11/4.
//




let CF_PORT_NAME = "group.nuclear.liveAPP.port"

//
//class CFMessagePortServer {
//
//    static let shared = CFMessagePortServer()
//
//    private var localPort: CFMessagePort?
//    private var runLoopSource: CFRunLoopSource?
//
//    private init() {}
//
//    // MARK: - Start Server
//    func start() {
//        // 如果已啟動，不重複建立
//        guard localPort == nil else { return }
//
//        var context = CFMessagePortContext(
//            version: 0,
//            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
//            retain: nil,
//            release: nil,
//            copyDescription: nil
//        )
//
//        var shouldFree: DarwinBoolean = false
//
//        localPort = CFMessagePortCreateLocal(
//            nil,
//            CF_PORT_NAME as CFString,
//            { port, msgid, data, info in
//                guard let info = info else { return nil }
//                let server = Unmanaged<CFMessagePortServer>.fromOpaque(info).takeUnretainedValue()
//                return server.handleMessage(msgid: msgid, data: data)
//            },
//            &context,
//            &shouldFree
//        )
//
//        guard let port = localPort else {
//            logger.error("Failed to create CFMessagePortServer")
//            return
//        }
//
//        runLoopSource = CFMessagePortCreateRunLoopSource(nil, port, 0)
//        if let source = runLoopSource {
//            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
//        }
//
//        logger.info("CFMessagePortServer started")
//    }
//
//    func stop() {
//        if let source = runLoopSource {
//            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
//        }
//        if let port = localPort {
//            CFMessagePortInvalidate(port)
//        }
//        localPort = nil
//        runLoopSource = nil
//        logger.info("CFMessagePortServer stopped")
//    }
//
//    // MARK: - Handle Messages
//    private func handleMessage(msgid: Int32, data: CFData?) -> Unmanaged<CFData>? {
//        guard let data = data as Data?,
//              let dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
//              let type = dict["type"] as? String else {
//            return emptyResponse()
//        }
//
//        switch type {
//        case "requestRTMP":
//            return respondRTMP()
//
//        case "requestSettings":
//            return respondAllSettings()
//
//        case "settings":
//            if let key = dict["key"] as? String, let value = dict["value"] {
//                userDefaults?.set(value, forKey: key)
////                logger.debug("Settings updated: \(key) = \(value)")
//            }
//            return emptyResponse()
//
//        case "log":
//            if let log = dict["message"] as? String {
//                appendLogToFile(log)
//                logger.debug("Log received: \(log)")
//            }
//            return emptyResponse()
//
//        default:
//            logger.debug("Unknown message type: \(type)")
//            return emptyResponse()
//        }
//    }
//
//    // MARK: - Responses
//    private func respondRTMP() -> Unmanaged<CFData>? {
//        let payload: [String: Any] = [
//            "type": "RTMP",
//            "rtmpURL": UserDefaults.standard.string(forKey: "rtmpURL") ?? "rtmp://192.168.0.102/live",
//            "rtmpKey": UserDefaults.standard.string(forKey: "rtmpKey") ?? "test"
//        ]
//
//        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
//            return emptyResponse()
//        }
//
//        return Unmanaged.passRetained(data as CFData)
//    }
//
//    private func respondAllSettings() -> Unmanaged<CFData>? {
//        let defaults = UserDefaults.standard.dictionaryRepresentation()
//        let payload: [String: Any] = [
//            "type": "settingsDump",
//            "data": defaults
//        ]
//        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
//            return emptyResponse()
//        }
//        return Unmanaged.passRetained(data as CFData)
//    }
//
//    private func emptyResponse() -> Unmanaged<CFData>? {
//        let data = "{}".data(using: .utf8)! as CFData
//        return Unmanaged.passRetained(data)
//    }
//
//    // MARK: - Logging
//    private func appendLogToFile(_ log: String) {
//        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
//            .first!.appendingPathComponent("extension.log")
//
//        let line = (log + "\n").data(using: .utf8)!
//
//        if FileManager.default.fileExists(atPath: fileURL.path),
//           let handle = try? FileHandle(forWritingTo: fileURL) {
//            handle.seekToEndOfFile()
//            handle.write(line)
//            handle.closeFile()
//        } else {
//            try? line.write(to: fileURL)
//        }
//    }
//}
