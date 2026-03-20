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
            guard let self = self, !self.buffer.isEmpty, let url = self.logURL else { return }

            let logsToSend = self.buffer

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

                if let error = error {
                    print("❌ Remote log failed:", error)
                    // 不清理 buffer
                } else {
                    // 成功發送才清理
                    self.queue.async {
                        self.buffer.removeAll()

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

    private let logFileName = "log.txt"
    private let groupID = "group.nuclear.liveAPP"

    // MARK: Rem Count
    private var localLogSize: Int = 0  // 累積字元數
    private let maxLogBufferSize = 1_000_000  // 約 1MB 上限，可自行調整

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
            self.localLogSize += logMessage.utf8.count

            logger.debug("LogBuffer:\(msg)")
        }
        
    }

    private init() {
        setupFlushTimer()
    }

    // MARK: 提前結束
    func forceFlush() {
        logQueue.sync {

            flushLocalLogs(forceNotify: true)

            flushTimer?.cancel()
            flushTimer = nil
            remoteLogger?.flush()
            remoteLogger = nil
            isActive = false
        }
    }

    func log(title: String = "ReplyKit", message: String, flushImmediately: Bool = false) {
        guard isActive else { return }

        let logMessage = "\(formattedTime()): \(title): \(message)\n"

        logQueue.async(flags: .barrier)  { [weak self] in
            guard let self = self else { return }


            switch self.mode {
            case .local:
                self.localLogBuffer.append(logMessage)
                self.localLogSize += logMessage.utf8.count
                if flushImmediately || self.localLogSize >= self.maxLogBufferSize {
                    self.flushLocalLogs()
                }

            case .remote:
                self.remoteLogger?.log(title: title, message: message)

            case .both:
                self.localLogBuffer.append(logMessage)
                self.localLogSize += logMessage.utf8.count
                if flushImmediately || self.localLogSize >= self.maxLogBufferSize {
                    self.flushLocalLogs()
                }
                self.remoteLogger?.log(title: title, message: message)
            }
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
                self.flushLocalLogs()
            }
        }
        flushTimer?.resume()
    }

    private func flushLocalLogs(forceNotify: Bool = false) {

            guard !localLogBuffer.isEmpty else { return }

            let bufferCopy = localLogBuffer.joined()
            localLogBuffer.removeAll()
            localLogSize = 0

            //統一這裡處理發送Socket轉送
            if RPConfig.shared.enableSocketLog {
                SocketClient.shared.sendLog(message: bufferCopy)
            }
        
            let containerURL: URL

            if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
                containerURL = groupURL
            } else {
                containerURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            }

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

            notifyMainAppIfNeeded(forceNotify: forceNotify)

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








final class RPConfig {
    static let shared = RPConfig()

    // RTMP 配置
    var RTMPURL : String? {
        didSet {
            guard oldValue != RTMPURL else {
                logger.debug("RTMPURL 一樣->\(oldValue as NSObject?)")
                return
            }
        }
    }
    var RTMPKey : String? {
        didSet {
            guard oldValue != RTMPKey else {
                logger.debug("RTMPKey 一樣")
                return
            }
        }
    }

    var h264level : String {
        didSet {
            guard oldValue != h264level else { return }
        }
    }

    var BufferCount : Int

    var BitRate : Int
    
    var ChangeBit : Bool

    var useBic : Bool

    var Rotate : Int
    var RotateOriginal : Bool

    // 音訊
    var AppVolumeAdd : Double
    var MicVolumeAdd : Double

    var AppVolume : Double
    var MicVolume : Double

    var ADWidth : Int
    var ADHeight : Int

    var ODWidth : Int
    var ODHeight : Int



    // 日誌相關
    var enableTimeDebug:Bool

    var enableSocketLog: Bool = false

    var enableRotateLog: Bool = false
    var enableLog: Bool = false
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

        enableRotateLog = SharedDefaults.group?.bool(forKey: "EnableRotatelog") ?? false

        enableSocketLog = SharedDefaults.group?.bool(forKey: "EnableSocketlog") ?? false


        enableLog=SharedDefaults.group?.bool(forKey: "Enablelog")
        ?? false

        onLogPage=SharedDefaults.group?.bool(forKey: "onlogPage")
        ?? false

        onAudioPage=SharedDefaults.group?.bool(forKey: "onAudioPage") ?? false





        // RTMP
        RTMPURL = SharedDefaults.group?.string(forKey: "rtmpURL")
        ?? "rtmp://192.168.0.102/live"

        RTMPKey = SharedDefaults.group?.string(forKey: "rtmpKey")
        ?? "stream1?vhost=live2"

        BitRate = SharedDefaults.group?.integer(forKey: "bitRate") ?? 3_900_000

        ChangeBit = SharedDefaults.group?.bool(forKey: "ChangeBit") ?? false

        useBic = SharedDefaults.group?.bool(forKey: "useBic") ?? false

        h264level = SharedDefaults.group?.string(forKey: "h264level") ?? "AutoHigh"


        BufferCount =  SharedDefaults.group?.integer(forKey: "BufferCount") ?? 5


        // AppVolume
        AppVolumeAdd = SharedDefaults.group?.double(forKey: "appAddVolume") ?? 1.0
        MicVolumeAdd = SharedDefaults.group?.double(forKey: "micAddVolume") ?? 1.0

        AppVolume =  SharedDefaults.group?.double(forKey: "appVolume") ?? 1.0
        MicVolume =  SharedDefaults.group?.double(forKey: "micVolume") ?? 1.0

        // Width 給GPU處理用的寬高
        ADWidth = SharedDefaults.group?.integer(forKey: "dstW") ?? 0
        ADHeight = SharedDefaults.group?.integer(forKey: "dstH") ?? 0

        // 控制輸出畫布寬高
        ODWidth = SharedDefaults.group?.integer(forKey: "odstW") ?? 0
        ODHeight = SharedDefaults.group?.integer(forKey: "odstH") ?? 0


        Rotate = SharedDefaults.group?.integer(forKey: "Rotate") ?? 90


        RotateOriginal = SharedDefaults.group?.bool(forKey: "RotateOriginal") ?? false



    }

    func applyLogMode() {
        LogManager.shared.setMode(logMode)
    }

    


}

var lastlogT = Date()
var IntTime:TimeInterval = 5.0


func sendlog(title: String = "ReplyKit", message: String, flush:Bool = false) {

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

            LogManager.shared.log(title:title,message: message,flushImmediately: flush)

            

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

    func teardown() {

        if let lp = localPort {
            CFMessagePortInvalidate(lp)
            localPort = nil
        }

        if let rp = remotePort {
            CFMessagePortInvalidate(rp)
            remotePort = nil
        }

        endP = nil

        LogManager.shared.log(message: "🧹 Extension CFMessagePort 停用")
    }

    private func setupReceiver() {

        teardown()


        var context = CFMessagePortContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            retain: { info in
                let unmanaged = Unmanaged<ExtensionMessagePort>.fromOpaque(info!)
                _ = unmanaged.retain()
                return info
            },
            release: { info in
                Unmanaged<ExtensionMessagePort>.fromOpaque(info!).release()
            },
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

        guard let lp = CFMessagePortCreateLocal(
            nil,
            "group.nuclear.liveAPP.ExtPort" as CFString,
            callback,
            &context,
            nil
        ) else {
            LogManager.shared.log(message: "❌ Extension Port 建立失敗")
            return
        }

        localPort = lp
        endP = CFMessagePortGetName(lp)

        if let localPort {
            let rl = CFMessagePortCreateRunLoopSource(nil, localPort, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), rl, .defaultMode)
        }

        LogManager.shared
            .log(message:"Port Add Ext \(String(describing: endP))")
    }

    func connectToApp() {
        disconnectFromApp()
        
        guard let rp = CFMessagePortCreateRemote(
            nil,
            "group.nuclear.liveAPP.AppPort" as CFString
        ) else {
            LogManager.shared.log(message: "❌ 無法連接 App Port")
            return
        }

        remotePort = rp

        LogManager.shared
            .log(message:"App連接建立!")
        ExtensionMessagePort.shared.send(toApp: ["test":"ok"])

    }

    func disconnectFromApp() {
        if remotePort != nil {
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

        let status = CFMessagePortSendRequest(
            remote,
            100,
            data as CFData,
            1,
            1,
            nil,
            nil
        )

        if status != kCFMessagePortSuccess {
            LogManager.shared.log(message: "❌ Send 失敗 \(status)，斷線")
            disconnectFromApp()
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


