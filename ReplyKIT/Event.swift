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
        }
    }

    func log(title: String = "ReplyKit", message: String) {
        let logMessage = "\(formattedTime()): \(title): \(message)\n"

        logQueue.async {


            switch self.mode {
                    case .local:
                        self.localLogBuffer.append(logMessage)
                        self.localLogSize += logMessage.utf8.count

                        self.localLogBuffer.append(logMessage)


                        if self.localLogSize >= self.maxLogBufferSize {
                            self.flushLocalLogs()
                        }

                    case .remote:
                        self.remoteLogger?.log(title: title, message: message)
                    case .both:

                        self.localLogBuffer.append(logMessage)
                        self.localLogSize += logMessage.utf8.count


                        self.localLogBuffer.append(logMessage)
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
        logMode=userDefaults?.integer(forKey: "logMode") ?? 1
        onLogPage=userDefaults?.bool(forKey: "onlogPage") ?? false
        enableLog=userDefaults?.bool(forKey: "Enablelog") ?? false
        logURL = userDefaults?.string(forKey: "logURL") ?? "http://192.168.0.242:3000/post"

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

        switch RPConfig.shared.logMode {
        case 1:
            LogManager.shared.mode = .local
        case 0:
            LogManager.shared.mode = .remote
        case 2:
            LogManager.shared.mode = .both
        default:
            LogManager.shared.mode = .local

        }

        if RPConfig.shared.onLogPage {
            LogManager.shared.log(title: title, message: message)
        }

    }
}

