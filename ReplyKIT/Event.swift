import Foundation
import os



// MARK: TimeFormat
func formattedTime() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
}

// MARK: - Remote Logging
//func sendRemoteLog(title: String = "ReplyKit", message: String) {
//    guard let urlString = userDefaults?.string(forKey: "logURL"),
//          let url = URL(string: urlString) else {
//        print("❌ URL 無效")
//        return
//    }
//
//    let timeString = formattedTime()
//    let json: [String: Any] = [
//        "title": title,
//        "body": message,
//        "time": timeString
//    ]
//
//    guard let httpBody = try? JSONSerialization.data(withJSONObject: json) else {
//        print("❌ JSON 轉換失敗")
//        return
//    }
//
//    var request = URLRequest(url: url)
//    request.httpMethod = "POST"
//    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
//    request.httpBody = httpBody
//
//    URLSession.shared.dataTask(with: request) { data, response, error in
//        if let error = error {
//            print("❌ 發送失敗:", error)
//            return
//        }
//
//        if let data = data,
//           let responseString = String(data: data, encoding: .utf8) {
//            print("✅ 收到回應:", responseString)
//        }
//    }.resume()
//}

// MARK: RemoteLogger
final class RemoteLogger {
    private var buffer: [[String: Any]] = []
    private let queue = DispatchQueue(label: "com.liveapp.remoteLogger", qos: .utility)

    // MARK: flushTime
    private let flushInterval: TimeInterval = 1.0
    private var flushTimer: DispatchSourceTimer?

    // MARK: Rem Count
    private var RemoteLogSize: Int = 0  // 累積的字元數
    private let maxLogBufferSize = 1_000_000  // 約 1MB 上限，可自行調整


    private var logURL: URL? = URL(string:RPConfig.shared.logURL)


    init() {
        logger.debug("RPlogURL: \(self.logURL?.absoluteString ?? "nil")")

        setupFlushTimer()
    }

    deinit {
        flushTimer?.setEventHandler {}  // 清空 closure
        flushTimer?.cancel()
        flushTimer = nil

        // 直接清理 buffer，不用呼叫 flush() 觸發 URLSession
        buffer.removeAll()
        RemoteLogSize = 0
    }

    func log(title: String, message: String) {
        let time = Date()
        let entry: [String: Any] = ["title": title, "body": message, "time": time.description]

        queue.async {
            self.buffer.append(entry)

            // 計算 entry 真實大小
            if let data = try? JSONSerialization.data(withJSONObject: entry) {
                self.RemoteLogSize += data.count
            }


            if self.RemoteLogSize >= self.maxLogBufferSize {
                self.flush()

            }
        }
    }

    private func setupFlushTimer() {

        // 先取消舊的 timer
        flushTimer?.cancel()
        flushTimer = nil

        flushTimer = DispatchSource.makeTimerSource(queue: queue)
        flushTimer?.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        flushTimer?.setEventHandler { [weak self] in
            self?.flush()
        }
        flushTimer?.resume()
    }

    func flush() {
        queue.async { [weak self] in
            guard let self = self, !self.buffer.isEmpty, let url = self.logURL else { return }

            let logsToSend = self.buffer
            guard let body = try? JSONSerialization.data(withJSONObject: logsToSend) else { return }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body

            URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
                guard let self = self else { return }

                if let error = error {
                    print("❌ Remote log failed:", error)
                    // 不清理 buffer
                } else {
                    // 成功發送才清理
                    self.queue.async {
                        self.buffer.removeAll()
                        self.RemoteLogSize = 0
                    }
                }
            }.resume()
        }
    }
}



final class LogManager {
    static let shared = LogManager()

    enum Mode { case local, remote ,both }

    private let logQueue = DispatchQueue(label: "com.liveapp.logQueue", qos: .utility)
    private var localLogBuffer: [String] = []

    private let logFileName = "log.txt"
    private let groupID = "group.nuclear.liveAPP"

    // MARK: Rem Count
    private var localLogSize: Int = 0  // 累積的字元數
    private let maxLogBufferSize = 1_000_000  // 約 1MB 上限，可自行調整

    // MARK: flush寫入間隔
    var flushInterval: TimeInterval = 1.0
    var flushTimer: DispatchSourceTimer?

    var isActive = true


    private var lastNotifyTime: Date = .distantPast

    var notifyThrottle: TimeInterval = 1.0

    private var remoteLogger: RemoteLogger?

    var mode: Mode = .local {
        didSet {
            switch mode {
            case .remote:
                if remoteLogger == nil { remoteLogger = RemoteLogger() }
            case .local:
                remoteLogger?.flush()
                remoteLogger = nil

            case .both:
                if remoteLogger == nil { remoteLogger = RemoteLogger() }


            }



        }
    }

    private init() {
        setupFlushTimer()
    }

    // MARK: 提前結束
    func forceFlush() {
        logQueue.sync {
            flushLocalLogs()
            // 先取消舊的 timer
            flushTimer?.cancel()
            flushTimer = nil
            remoteLogger?.flush()
            remoteLogger = nil

            isActive = false
        }
    }

    func log(title: String = "ReplyKit", message: String) {
        
        if !isActive {
            return
        }
        
        let logMessage = "\(formattedTime()): \(title): \(message)\n"

        logQueue.async {


            switch self.mode {
                    case .local:
                        self.localLogBuffer.append(logMessage)
                        self.localLogSize += logMessage.utf8.count

                        if self.localLogSize >= self.maxLogBufferSize {
                            self.flushLocalLogs()
                        }

                    case .remote:
                        self.remoteLogger?.log(title: title, message: message)
                    case .both:

                        self.localLogBuffer.append(logMessage)
                        self.localLogSize += logMessage.utf8.count

                        if self.localLogSize >= self.maxLogBufferSize {
                            self.flushLocalLogs()
                        }

                        self.remoteLogger?.log(title: title, message: message)
                    }


        }
    }

    func setupFlushTimer() {

        // 先取消舊的 timer
        flushTimer?.cancel()
        flushTimer = nil

        isActive = true

        // 延遲通知主 App
        let now = Date()
        lastNotifyTime = now
        flushTimer = DispatchSource.makeTimerSource(queue: logQueue)
        flushTimer?.schedule(deadline: .now() + flushInterval, repeating: flushInterval)

        flushTimer?.setEventHandler { [weak self] in
            guard let self = self else { return }

            if self.mode == .local || self.mode == .both {
                    self.flushLocalLogs()
            }

        }
        flushTimer?.resume()
    }

    private func flushLocalLogs() {
        guard !localLogBuffer.isEmpty else { return }
        let bufferCopy = localLogBuffer.joined()
        localLogBuffer.removeAll()
        localLogSize = 0



        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return }
        let fileURL = containerURL.appendingPathComponent(logFileName)

        if let data = bufferCopy.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: fileURL.path),
               let fileHandle = try? FileHandle(forWritingTo: fileURL) {
                defer { fileHandle.closeFile() }
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }

        // 延遲通知主 App
        let now = Date()
        if now.timeIntervalSince(lastNotifyTime) > notifyThrottle {
            lastNotifyTime = now
            DispatchQueue.global(qos: .utility).async {
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("liveAPP.log" as CFString),
                    nil,
                    nil,
                    true
                )
            }
        }
    }


}






//
//    private func formattedTime() -> String {
//        let formatter = DateFormatter()
//        formatter.dateStyle = .short
//        formatter.timeStyle = .medium
//        formatter.locale = Locale.current
//        return formatter.string(from: Date())
//    }
//}


final class RPConfig {
    static let shared = RPConfig()

    private init() {
        logMode=SharedDefaults.group?.integer(forKey: "logMode")
        ?? 1
        onLogPage=SharedDefaults.group?.bool(forKey: "onlogPage")
        ?? false
        enableLog=SharedDefaults.group?.bool(forKey: "Enablelog")
        ?? false
        logURL = SharedDefaults.group?.string(forKey: "logURL") ?? "http://192.168.0.242:3000/post"


        switch logMode {
        case 1:
            LogManager.shared.mode = .local
        case 0:
            LogManager.shared.mode = .remote
        case 2:
            LogManager.shared.mode = .both
        default:
            LogManager.shared.mode = .local

        }

    }

    

    // 日誌相關
    var enableLog: Bool = false
    var logMode: Int = 1
    var onLogPage: Bool = false
    var logURL:String = "http://192.168.0.242:3000/post"

    // 其他配置
    var maxInflightFrames: Int = 4

}

var lastlogT = Date()
var IntTime:TimeInterval = 5.0


func sendlog(title: String = "ReplyKit", message: String, mode: Int = 0) {

    let noww=Date()

    if noww.timeIntervalSince(lastlogT) > IntTime {
        lastlogT=noww

        logger
            .info(
                "RP: EnableLog:\(RPConfig.shared.enableLog) onlog:\(RPConfig.shared.onLogPage)"
            )
    }

    if RPConfig.shared.enableLog {



        if RPConfig.shared.onLogPage {
            LogManager.shared.log(title:title,message: message)
            //SocketClient.shared.sendLog(title: title, message: message)
        }

    }
}



//MARK: CFPort

final class ExtensionMessagePort {
    static let shared = ExtensionMessagePort()

    private var localPort: CFMessagePort?
    private var remotePort: CFMessagePort?

    var endP : CFString?

    private init() {
        setupReceiver()
    }

    private func setupReceiver() {
        var context = CFMessagePortContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: CFMessagePortCallBack = { port, msgid, cfData, info -> Unmanaged<CFData>? in

            if let data = cfData as Data?,
               let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
               let str = String(data: pretty, encoding: .utf8) {

                LogManager.shared
                    .log(message:"📨 Extension 收到來自 App 的訊息:\n\(str)")

            } else {
                LogManager.shared
                    .log(message:"📨 Extension Not Get 來自 App 的訊息")


            }
            return nil
        }

        localPort = CFMessagePortCreateLocal(nil,
                                             "group.nuclear.liveAPP.ExtPort" as CFString,
                                             callback,
                                             &context,
                                             nil)

        endP = CFMessagePortGetName(localPort)

        if let localPort {
            let rl = CFMessagePortCreateRunLoopSource(nil, localPort, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), rl, .defaultMode)
        }

        LogManager.shared
            .log(message:"Port Add Ext \(String(describing: endP))")
    }

    func connectToApp() {
        remotePort = CFMessagePortCreateRemote(nil, "group.nuclear.liveAPP.AppPort" as CFString)

        LogManager.shared
            .log(message:"App連接建立!")
        ExtensionMessagePort.shared.send(toApp: ["test":"ok"])

    }

    func disconnectFromApp() {
        if let port = remotePort {
            CFMessagePortInvalidate(remotePort)
            remotePort = nil
            LogManager.shared.log(message: "App連接已取消")
        }
    }

    func send(toApp dict: [String: Any]) {
        guard
            let remote = remotePort,
            let data = try? JSONSerialization.data(withJSONObject: dict)
        else { return }

        CFMessagePortSendRequest(
            remote,
            100,                 // message id
            data as CFData,
            1,
            1,
            nil,
            nil
        )
    }

}


