import Foundation
import os




// 全局共用時間 liveApp格式器
struct StaticFormatter {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_TW")
        f.dateFormat = "yyyy/MM/dd aHH:mm:ss.SSS"
        return f
    }()
}

// MARK: TimeFormat
func formattedTime() -> String {
    let formatter = StaticFormatter.formatter
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
    private var isFlushing = false


    private let queue = DispatchQueue(label: "com.liveapp.remoteLogger", qos: .utility)

    // MARK: flushTime
    private let flushInterval: TimeInterval = 1.0
    private var flushTimer: DispatchSourceTimer?

    private let maxLogCount = 500  // 500 條 上限，可自行調整


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

    }

    func addDebugLog(title:String = "ReplyKit[Remote]", _ msg:String = ""){

        let time = Date()
        let entry: [String: Any] = ["title": title, "body": msg, "time": time.description]


        self.buffer.append(entry)
        logger.debug("RemoteLogBuffer:\(msg)")
    }

    func log(title: String, message: String) {
        let time = Date()
        let entry: [String: Any] = ["title": title, "body": message, "time": time.description]

        queue.async { [self] in
            self.buffer.append(entry)

            // ✅ 不再每條 log 立即計算 JSON 大小
            // 只在 flush 時才計算整個 buffer 的大小
            if self.buffer.count >=  maxLogCount { // 可設定條數閾值，也可保持 flushInterval 控制
                self.flush()
            }
        }
    }

    func flush() {
        queue.async { [weak self] in
            guard let self = self, !self.buffer.isEmpty, let url = self.logURL, !self.isFlushing else { return }


            defer {
                self.buffer.removeAll()
            }
            
            let logsToSend = self.buffer
            
            self.isFlushing = true

            let payload: [String: Any] = [
                "logs": logsToSend
            ]

            // ✅ 只在 flush 時一次性序列化整個 buffer
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            
            request.httpBody = body

            URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
                guard let self = self else { return }
                defer { self.isFlushing = false }

                if error != nil {
                    self.queue.sync {
                        self.isFlushing = false
                        self.buffer.insert(contentsOf: logsToSend, at: 0)
                    }
                } else {
                    self.queue.sync {
                        self.isFlushing = false
                    }
                }

            }.resume()
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


}



// MARK: New LogManager
final class LogManager {
    static let shared = LogManager()

    enum Mode { case local, remote, both }

    private let logQueue = DispatchQueue(
        label: "com.liveapp.logQueue",
        qos: .background,
        attributes: .concurrent
    )

    private var localLogBuffer: [String] = []
    private let maxRingBufferEntries = 1000

    private let logFileName = "log.txt"
    private let earlyLogFileName = "early-log.txt"
    private let groupID = "group.nuclear.liveAPP"
    private let maxLogFileLines = 5000
    private let maxEarlyLogLines = 2000
    private let maxForceFlushLines = 200

    // MARK: flush寫入間隔
    var flushInterval: TimeInterval = 1.0
    private var flushTimer: DispatchSourceTimer?

    var isActive = true

    private var lastNotifyTime: Date = .distantPast
    var notifyThrottle: TimeInterval = 2.0

    private var remoteLogger: RemoteLogger?

    var mode: Mode = .local {
        didSet {
            switch mode {
            case .remote:
                if remoteLogger == nil {
                    remoteLogger = RemoteLogger()
                }
            case .local:
                remoteLogger?.flush()
                remoteLogger = nil
            case .both:
                if remoteLogger == nil {
                    remoteLogger = RemoteLogger()
                }
            }
        }
    }

    func setMode(_ Num:Int = 1){


        switch Num {
        case 0:
            self.mode = .remote
            
            remoteLogger?.addDebugLog("logMode : 只在外部")

        case 1:
            self.mode = .local
            addDebugLog("logMode : 只在App")
        case 2:
            self.mode = .both
            addDebugLog("logMode : 同時App + 外部")

            remoteLogger?.addDebugLog("logMode : 同時App + 外部")


        default:
            self.mode = .local
            addDebugLog("logMode : 只在App")

        }

    }



    func addDebugLog(title:String = "ReplyKit[Local]", _ msg:String = ""){

        let logMessage = "\(formattedTime()): \(title) : \(msg) \n"

        logQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            self.localLogBuffer.append(logMessage)
            if self.localLogBuffer.count > self.maxRingBufferEntries {
                self.localLogBuffer.removeFirst(self.localLogBuffer.count - self.maxRingBufferEntries)
            }

            self.writeEarlyLogToFile(logMessage)
            logger.debug("LogBuffer:\(msg)")
        }
        
    }

    private init() {
        setupFlushTimer()
    }

    // MARK: 提前結束
    func forceFlush() {
        guard !localLogBuffer.isEmpty else { return }
        let bufferCopy = localLogBuffer
        localLogBuffer = []

        notifyMainAppIfNeeded(forceNotify: true)

        if RPConfig.shared.enableSocketLog {
            let limited = Array(bufferCopy.suffix(maxForceFlushLines))
            SocketClient.shared.sendLogBatch(entries: limited)
            SocketClient.shared.forceFlushBatch()
        } else {
            let text = bufferCopy.joined()
            writeLogToFile(text)
        }

        flushTimer?.cancel()
        flushTimer = nil
        remoteLogger?.flush()
        remoteLogger = nil
        isActive = false
        
    }

    func log(title: String = "ReplyKit", message: String, flushImmediately: Bool = false) {
        guard isActive else { return }

        let logMessage = "\(formattedTime()): \(title): \(message)\n"

        logQueue.async(flags: .barrier)  { [weak self] in
            guard let self = self else { return }


            switch self.mode {
            case .local:
                self.localLogBuffer.append(logMessage)
                if self.localLogBuffer.count > self.maxRingBufferEntries {
                    self.localLogBuffer.removeFirst(self.localLogBuffer.count - self.maxRingBufferEntries)
                }
                if flushImmediately {
                    self.flushLocalLogs()
                }

            case .remote:
                self.remoteLogger?.log(title: title, message: message)

            case .both:
                self.localLogBuffer.append(logMessage)
                if self.localLogBuffer.count > self.maxRingBufferEntries {
                    self.localLogBuffer.removeFirst(self.localLogBuffer.count - self.maxRingBufferEntries)
                }
                if flushImmediately {
                    self.flushLocalLogs()
                }
                self.remoteLogger?.log(title: title, message: message)
            }
            self.writeEarlyLogToFile(logMessage)
        }
    }

    func setupFlushTimer() {
        flushTimer?.cancel()
        flushTimer = nil

        isActive = true
        lastNotifyTime = Date()

        flushTimer = DispatchSource.makeTimerSource(queue: logQueue)
        flushTimer?.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        flushTimer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.mode == .local || self.mode == .both {
                // onLogPage 為 false 時只清空 buffer，不寫入檔案或 socket
                // 側載模式無 App Group，必須強制走 socket，不受 onLogPage 限制
                // ring buffer 自動 drop 最舊的，overflow 不累積
                if RPConfig.isSideload || RPConfig.shared.onLogPage {
                    self.flushLocalLogs()
                } else {
                    self.localLogBuffer.removeAll()
                }
            }
        }
        flushTimer?.resume()
    }

    private func flushLocalLogs(forceNotify: Bool = false) {
        guard !localLogBuffer.isEmpty else { return }

        let bufferCopy = localLogBuffer
        localLogBuffer = []

        notifyMainAppIfNeeded(forceNotify: forceNotify)

        if RPConfig.shared.enableSocketLog {
            DispatchQueue.global(qos: .utility).async {
                SocketClient.shared.sendLogBatch(entries: bufferCopy, force: true)
            }
        } else {
            let text = bufferCopy.joined()
            writeLogToFile(text)
        }
    }

    private func writeLogToFile(_ text: String) {
        guard !RPConfig.isSideload else { return }
        let containerURL: URL
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            containerURL = groupURL
        } else {
            containerURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        }
        let fileURL = containerURL.appendingPathComponent(logFileName)
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path),
           let fileHandle = try? FileHandle(forWritingTo: fileURL) {
            defer { fileHandle.closeFile() }
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
        trimLogFileIfNeeded(fileURL: fileURL)
    }

    private func trimLogFileIfNeeded(fileURL: URL) {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL),
              let currentData = try? fileHandle.readToEnd()
        else { return }
        fileHandle.closeFile()
        guard let content = String(data: currentData, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLogFileLines else { return }
        let hasSuffixNewline = content.hasSuffix("\n")
        let trimmedLines = lines.suffix(maxLogFileLines)
        let trimmedText = trimmedLines.joined(separator: "\n") + (hasSuffixNewline ? "\n" : "")
        try? trimmedText.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func writeEarlyLogToFile(_ text: String) {
        guard !RPConfig.isSideload else { return }
        let fileURL = earlyLogFileURL()
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path),
           let fileHandle = try? FileHandle(forWritingTo: fileURL) {
            defer { fileHandle.closeFile() }
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
        trimEarlyLogFileIfNeeded(fileURL: fileURL)
    }

    private func earlyLogFileURL() -> URL {
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            return groupURL.appendingPathComponent(earlyLogFileName)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent(earlyLogFileName)
    }

    private func trimEarlyLogFileIfNeeded(fileURL: URL) {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL),
              let currentData = try? fileHandle.readToEnd()
        else { return }
        fileHandle.closeFile()
        guard let content = String(data: currentData, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxEarlyLogLines else { return }
        let hasSuffixNewline = content.hasSuffix("\n")
        let trimmedLines = lines.suffix(maxEarlyLogLines)
        let trimmedText = trimmedLines.joined(separator: "\n") + (hasSuffixNewline ? "\n" : "")
        try? trimmedText.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - 通知主 App（優化版）
    private func notifyMainAppIfNeeded(forceNotify: Bool = false) {

        let now = Date()

//        logger
//            .debug(
//                "last?:\(self.lastNotifyTime.timeIntervalSinceNow) 通知->\(self.notifyThrottle)"
//            )
        // 設定浮動範圍 1~3 秒
        let throttleWithJitter = Double.random(in: 1...notifyThrottle)


        if !forceNotify && lastNotifyTime
            .timeIntervalSinceNow > -throttleWithJitter {
            logger
                .debug(
                    "last:\(self.lastNotifyTime.timeIntervalSinceNow) 跳過通知->\(throttleWithJitter)"
                )
            return
        }


        lastNotifyTime = now

        // 直接在 logQueue 執行，避免不必要的 context switch
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("liveAPP.log" as CFString),
            nil,
            nil,
            true
        )
    }

    // MARK: - 時間格式化
    private func formattedTime() -> String {
        let formatter = StaticFormatter.formatter
        return formatter.string(from: Date())
    }
}






// MARK: RPConfig - 全局配置管理

final class RPConfig {
    static let shared = RPConfig()


    struct State {
        // RTMP 配置
        var RTMPURL : String?
        var RTMPKey : String?

        var h264level : String = "AutoHight"
        var BitRateMode: Int = 0
        var BufferCount : Int = 3
        var BitRate : Int = 6_000_000
        var ChangeBit : Bool = false

        var isLowLatencyRateControlEnabled : Bool = true
        var useEnhancedRTMP : Bool = true
        var isOringinAudio : Bool = true

        var useBic : Bool = false

        var Rotate : Int = 90
        var RotateOriginal : Bool = false

        // 輸出寬高
        var ADWidth : Int = 0
        var ADHeight : Int = 0

        var ODWidth : Int = 0
        var ODHeight : Int = 0

        // 音訊處理
        var AppVolume : Double = 1.0
        var MicVolume : Double = 1.0

        var AppVolumeAdd : Double = 1.0
        var MicVolumeAdd : Double = 1.0

        // 降噪處理
        var enableNoiseFix : Bool = false
        
        // 回音處理
        var enableEchoFix : Bool = false 
        // 自動增益
        var enableAGCFix : Bool = false
        // Metal 加速降噪
        var enableMetalAudio : Bool = false

        // 關鍵幀間隔（秒），0=編碼器自動，>0=固定
        var KeyFrameInterval : Int = 0

        // RTMP 內部日誌
        var enableRTMPLog : Bool = true

    }

    var state: State


    // MARK: - Public control API
    // ======================================================
    // 🎛 unified Audio state update
    // ======================================================
    func updateAudio(
                    isOringinAudio:Bool? = nil,
                    AppVolume:Double? = nil,
                    MicVolume:Double? = nil,
                    AppVolumeAdd:Double? = nil,
                    MicVolumeAdd:Double? = nil,
                    enableNoiseFix:Bool? = nil,
                    enableEchoFix:Bool? = nil,
                    enableAGCFix:Bool? = nil,
                    enableMetalAudio:Bool? = nil 
                    ) {

            if let isOringinAudio = isOringinAudio {
                self.state.isOringinAudio = isOringinAudio
            }

            if let AppVolume = AppVolume {
                self.state.AppVolume = AppVolume
            }
            if let MicVolume = MicVolume {
                self.state.MicVolume = MicVolume
            }
            
            if let AppVolumeAdd = AppVolumeAdd {
                self.state.AppVolumeAdd = AppVolumeAdd
            }
            if let MicVolumeAdd = MicVolumeAdd {
                self.state.MicVolumeAdd = MicVolumeAdd
            }


            if let enableNoiseFix = enableNoiseFix {
                self.state.enableNoiseFix = enableNoiseFix 
            }

            if let enableEchoFix = enableEchoFix {
                self.state.enableEchoFix = enableEchoFix 
            }
            
            if let enableAGCFix = enableAGCFix {
                self.state.enableAGCFix = enableAGCFix 
            }

            if let enableMetalAudio = enableMetalAudio {
                self.state.enableMetalAudio = enableMetalAudio
            }

    }

    // MARK: - Public control API
    // ======================================================
    // 🎛 unified state update
    // ======================================================
    func updateState(RTMPURL:String? = nil,
                     RTMPKey:String? = nil,
                     h264level:String? = nil,
                     BitRateMode:Int? = nil,
                     BufferCount:Int? = nil,
                     BitRate:Int? = nil,
                     ChangeBit:Bool? = nil,
                      isLowLatencyRateControlEnabled:Bool? = nil,
                      useEnhancedRTMP:Bool? = nil,
                      useBic:Bool? = nil,
                     Rotate:Int? = nil,
                     RotateOriginal:Bool? = nil,
                     ADWidth:Int? = nil,
                     ADHeight:Int? = nil,
                     ODWidth:Int? = nil,
                     ODHeight:Int? = nil,
                      KeyFrameInterval:Int? = nil,
                      enableRTMPLog:Bool? = nil,
                      ) {

            if let RTMPURL = RTMPURL {
                self.state.RTMPURL = RTMPURL
            }

            if let RTMPKey = RTMPKey {
                self.state.RTMPKey = RTMPKey
            }


            if let h264level = h264level {
                self.state.h264level = h264level
            }

            if let BitRateMode = BitRateMode {
                self.state.BitRateMode = BitRateMode
            }

            if let BufferCount = BufferCount {
                self.state.BufferCount = BufferCount
            }

            if let BitRate = BitRate {
                self.state.BitRate = BitRate
            }
            

            if let ChangeBit = ChangeBit {
                self.state.ChangeBit = ChangeBit
            }


            if let isLowLatencyRateControlEnabled = isLowLatencyRateControlEnabled {
                self.state.isLowLatencyRateControlEnabled = isLowLatencyRateControlEnabled
            }

            if let useEnhancedRTMP = useEnhancedRTMP {
                self.state.useEnhancedRTMP = useEnhancedRTMP
            }

            if let useBic = useBic {
                self.state.useBic = useBic
            }

            if let Rotate = Rotate {
                self.state.Rotate = Rotate
            }

            if let RotateOriginal = RotateOriginal {
                self.state.RotateOriginal = RotateOriginal
            }

            if let ADWidth = ADWidth {
                self.state.ADWidth = ADWidth
                sendlog(message:"原始寬度:\(String(describing: ADWidth))")
                
            }
            if let ADHeight = ADHeight {
                self.state.ADHeight = ADHeight
                sendlog(message:"原始高度:\(String(describing: ADHeight))")
            }
            if let ODWidth = ODWidth {
                self.state.ODWidth = ODWidth
                sendlog(message:"輸出寬度:\(String(describing: ODWidth))")
            }
            if let ODHeight = ODHeight {
                self.state.ODHeight = ODHeight

                sendlog(message:"輸出高度:\(String(describing: ODHeight))")
            }

            if let KeyFrameInterval = KeyFrameInterval {
                self.state.KeyFrameInterval = KeyFrameInterval
            }

            if let enableRTMPLog = enableRTMPLog {
                self.state.enableRTMPLog = enableRTMPLog
            }

    }


    // 日誌相關
    var enableTimeDebug:Bool
    var enablePipelineLog:Bool = false
    var enableSocketLog: Bool = false
    var enableRotateLog: Bool = false

    static var isSideload: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.nuclear.liveAPP") == nil
    }

    var enableLog: Bool = true
    var logMode: Int = 1
    var onLogPage: Bool = false

    var onAudioPage : Bool = false

    var logURL:String = "http://192.168.0.242:3000/post"

    // 其他配置
    var maxInflightFrames: Int = 4

    private init() {

        logMode=SharedDefaults.group?.integer(forKey: "logMode")
        ?? 1

        logURL = SharedDefaults.group?.string(forKey: "logURL") ?? "http://192.168.0.242:3000/post"


        enableTimeDebug = SharedDefaults.group?
            .bool(forKey: "EnableTimeDebug") ?? false

        enablePipelineLog = SharedDefaults.group?
            .bool(forKey: "EnablePipelineLog") ?? false

        enableRotateLog = SharedDefaults.group?.bool(forKey: "EnableRotatelog") ?? false

        enableSocketLog = SharedDefaults.group?.bool(forKey: "EnableSocketlog") ?? false
        if Self.isSideload {
            enableSocketLog = true
        }

        enableLog=SharedDefaults.group?.bool(forKey: "Enablelog")
        ?? true

        onLogPage=SharedDefaults.group?.bool(forKey: "onlogPage")
        ?? true

        onAudioPage=SharedDefaults.group?.bool(forKey: "onAudioPage") ?? false

        

        self.state = State(
            RTMPURL:SharedDefaults.group?.string(forKey: "rtmpURL") ?? "rtmp://192.168.0.102/live",
            RTMPKey:SharedDefaults.group?.string(forKey: "rtmpKey")  ?? "stream1?vhost=live2",
            h264level:SharedDefaults.group?.string(forKey: "h264level") ?? "AutoHigh",
            BufferCount:SharedDefaults.group?.integer(forKey: "BufferCount") ?? 3,
            BitRate:SharedDefaults.group?.integer(forKey: "bitRate") ?? 6_000_000,
            
            ChangeBit:SharedDefaults.group?.bool(forKey: "ChangeBit") ?? false,
            isLowLatencyRateControlEnabled:SharedDefaults.group?.bool(forKey: "isLowLatencyRateControlEnabled") ?? true,
            useEnhancedRTMP:SharedDefaults.group?.object(forKey: "useEnhancedRTMP") as? Bool ?? true,
            isOringinAudio: (SharedDefaults.group?.object(forKey: "isOringinAudio") as? Bool) ?? true,
            useBic:SharedDefaults.group?.bool(forKey: "useBic") ?? false,
            
            // 方向處理
            Rotate: (SharedDefaults.group?.object(forKey: "Rotate") as? Int) ?? 90,

            RotateOriginal:SharedDefaults.group?.object(forKey: "RotateOriginal") as? Bool ?? false,

             // Width 給GPU處理用的寬高
            ADWidth:SharedDefaults.group?.integer(forKey: "dstW") ?? 0,
            ADHeight:SharedDefaults.group?.integer(forKey: "dstH") ?? 0,
            // 控制輸出畫布寬高
            ODWidth:SharedDefaults.group?.integer(forKey: "odstW") ?? 0,
            ODHeight:SharedDefaults.group?.integer(forKey: "odstH") ?? 0,
            
            // 音訊音量
            AppVolume:SharedDefaults.group?.double(forKey: "appVolume") ?? 1.0,
            MicVolume:SharedDefaults.group?.double(forKey: "micVolume") ?? 1.0,

            AppVolumeAdd:SharedDefaults.group?.double(forKey: "appAddVolume") ?? 1.0,
            MicVolumeAdd:SharedDefaults.group?.double(forKey: "micAddVolume") ?? 1.0,
            // 音訊降噪 頻譜處理
            enableNoiseFix:SharedDefaults.group?.bool(forKey: "enableNoiseFix") ?? false,

            // 音訊回音消除
            enableEchoFix:SharedDefaults.group?.bool(forKey: "enableEchoFix") ?? false,

             // 音訊自動增益
            enableAGCFix:SharedDefaults.group?.bool(forKey: "enableAGCFix") ?? false,
            // Metal 音訊降噪
            enableMetalAudio:SharedDefaults.group?.bool(forKey: "enableMetalAudio") ?? false,
            enableRTMPLog:SharedDefaults.group?.bool(forKey: "enableRTMPLog") ?? false
        )


    }

    func applyLogMode() {
        LogManager.shared.setMode(logMode)
    }

    


}

func updateLogFixState() {
    sendlog(message:"🔄 Log Enabled: \(RPConfig.shared.enableLog)")
}

func updateONLogFixState() {
    sendlog(message:"🔄 onLogPage: \(RPConfig.shared.onLogPage)")
}


func sendlog(title: String = "ReplyKit", message: String, flush: Bool = false) {
    guard RPConfig.shared.enableLog else {
        logger.debug("sendlog skipped: enableLog=\(RPConfig.shared.enableLog)")
        return
    }
    // onLogPage 只控制是否 flush 到外部（檔案/Socket），不控制是否寫入 buffer
    // 確保無日誌頁時 LogManager 仍正常緩衝，問題可事後追溯
    LogManager.shared.log(title: title, message: message, flushImmediately: flush && RPConfig.shared.onLogPage)
}



//MARK: CFPort 已停用 目前已由Socket為主

// final class ExtensionMessagePort {
//     static let shared = ExtensionMessagePort()

//     private var localPort: CFMessagePort?
//     private var remotePort: CFMessagePort?

//     var endP : CFString?

//     private init() {
//         setupReceiver()
//     }

//     func teardown() {

//         if let lp = localPort {
//             CFMessagePortInvalidate(lp)
//             localPort = nil
//         }

//         if let rp = remotePort {
//             CFMessagePortInvalidate(rp)
//             remotePort = nil
//         }

//         endP = nil

//         LogManager.shared.log(message: "🧹 Extension CFMessagePort 停用")
//     }

//     private func setupReceiver() {

//         teardown()


//         var context = CFMessagePortContext(
//             version: 0,
//             info: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
//             retain: { info in
//                 let unmanaged = Unmanaged<ExtensionMessagePort>.fromOpaque(info!)
//                 _ = unmanaged.retain()
//                 return info
//             },
//             release: { info in
//                 Unmanaged<ExtensionMessagePort>.fromOpaque(info!).release()
//             },
//             copyDescription: nil

//         )

//         let callback: CFMessagePortCallBack = { port, msgid, cfData, info -> Unmanaged<CFData>? in

//             if let data = cfData as Data?,
//                let obj = try? JSONSerialization.jsonObject(with: data),
//                let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
//                let str = String(data: pretty, encoding: .utf8) {

//                 LogManager.shared
//                     .log(message:"📨 Extension 收到來自 App 的訊息:\n\(str)")

//             } else {
//                 LogManager.shared
//                     .log(message:"📨 Extension Not Get 來自 App 的訊息")


//             }
//             return nil
//         }

//         guard let lp = CFMessagePortCreateLocal(
//             nil,
//             "group.nuclear.liveAPP.ExtPort" as CFString,
//             callback,
//             &context,
//             nil
//         ) else {
//             LogManager.shared.log(message: "❌ Extension Port 建立失敗")
//             return
//         }

//         localPort = lp
//         endP = CFMessagePortGetName(lp)

//         if let localPort {
//             let rl = CFMessagePortCreateRunLoopSource(nil, localPort, 0)
//             CFRunLoopAddSource(CFRunLoopGetMain(), rl, .defaultMode)
//         }

//         LogManager.shared
//             .log(message:"Port Add Ext \(String(describing: endP))")
//     }

//     func connectToApp() {
//         disconnectFromApp()
        
//         guard let rp = CFMessagePortCreateRemote(
//             nil,
//             "group.nuclear.liveAPP.AppPort" as CFString
//         ) else {
//             LogManager.shared.log(message: "❌ 無法連接 App Port")
//             return
//         }

//         remotePort = rp

//         LogManager.shared
//             .log(message:"App連接建立!")
//         ExtensionMessagePort.shared.send(toApp: ["test":"ok"])

//     }

//     func disconnectFromApp() {
//         if remotePort != nil {
//             CFMessagePortInvalidate(remotePort)
//             remotePort = nil
//             LogManager.shared.log(message: "App連接已取消")
//         }
//     }

//     func send(toApp dict: [String: Any]) {
//         guard
//             let remote = remotePort,
//             let data = try? JSONSerialization.data(withJSONObject: dict)
//         else { return }

//         let status = CFMessagePortSendRequest(
//             remote,
//             100,
//             data as CFData,
//             1,
//             1,
//             nil,
//             nil
//         )

//         if status != kCFMessagePortSuccess {
//             LogManager.shared.log(message: "❌ Send 失敗 \(status)，斷線")
//             disconnectFromApp()
//         }

//     }

// }


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


