//
//  liveAPPApp.swift
//  liveAPP
//
//  Created by user on 2025/8/24.
//

import SwiftUI

import UserNotifications
import AVFoundation
import Combine
#if os(iOS)
import BackgroundTasks
#endif

#if os(iOS)
import UIKit
import CoreMotion
#elseif os(macOS)
import AppKit
#endif



//
//  Event.swift
//  liveAPP
//
//  Created by user on 2025/9/13.

import os
import Foundation

extension Notification.Name {
    static let appLogNotification = Notification.Name("appLogNotification")
}

// 每個 log 項目
struct LogItem: Identifiable, Hashable {
    let id = UUID()
    let message: String
}



// MARK: 日誌緩衝區
final class LogBuffer {
    static let shared = LogBuffer()

    private let queue = DispatchQueue(label: "log.buffer.queue")
    private var buffer: [String] = []
    private var flushWorkItem: DispatchWorkItem?
    private let flushDelay: TimeInterval = 0.05
    private let batchLimit = 100
    private let maxBufferSize = 5000

    var onNewLog: (([String]) -> Void)?

    func push(_ msg: String) {
        queue.async {
            self.buffer.append(msg)
            self.trimIfNeededLocked()
            self.scheduleFlushLocked()
        }
    }

    func push(_ messages: [String]) {
        guard !messages.isEmpty else { return }

        queue.async {
            self.buffer.append(contentsOf: messages)
            self.trimIfNeededLocked()
            self.scheduleFlushLocked()
        }
    }

    private func trimIfNeededLocked() {
        guard buffer.count > maxBufferSize else { return }
        let excess = buffer.count - maxBufferSize
        buffer.removeFirst(excess)
    }

    private func scheduleFlushLocked() {
        guard flushWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.flushLocked()
        }
        flushWorkItem = workItem
        queue.asyncAfter(deadline: .now() + flushDelay, execute: workItem)
    }

    private func flushLocked() {
        flushWorkItem = nil
        guard !buffer.isEmpty else { return }

        let count = min(batchLimit, buffer.count)
        let logs = Array(buffer.prefix(count))
        buffer.removeFirst(count)

        DispatchQueue.main.async {
            self.onNewLog?(logs)
        }

        if !buffer.isEmpty {
            scheduleFlushLocked()
        }

    }

    func clear() {
        queue.async {
            self.flushWorkItem?.cancel()
            self.flushWorkItem = nil
            self.buffer.removeAll()
        }
    }
}


// MARK: - Documents 日誌持久化（供檔案 App 讀取）
final class AppLogPersister {
    static let shared = AppLogPersister()
    private let queue = DispatchQueue(label: "liveApp.logPersister", qos: .utility)
    private let logFileName = "log.txt"
    private let maxLogFileLines = 5000
    private let trimMargin = 2000

    /// 記憶體中估算行數，避免每次寫入都讀檔
    private var estimatedLineCount = 5000
    private var trimScheduled = false

    private var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent(logFileName)
    }

    

    func append(line: String) {
        queue.async {
            guard let data = (line + "\n").data(using: .utf8) else { return }
            self.write(data)
        }
    }

    func append(lines: [String]) {
        guard !lines.isEmpty else { return }
        queue.async {
            let text = lines.joined(separator: "\n") + "\n"
            guard let data = text.data(using: .utf8) else { return }
            self.write(data)
        }
    }

    func copyFromAppGroup() {
        queue.async {
            guard let groupURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.nuclear.liveAPP"
            ) else { return }
            let source = groupURL.appendingPathComponent(self.logFileName)
            guard FileManager.default.fileExists(atPath: source.path),
                  let data = try? Data(contentsOf: source) else { return }
            if FileManager.default.fileExists(atPath: self.logURL.path),
               let handle = try? FileHandle(forWritingTo: self.logURL) {
                defer { handle.closeFile() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: self.logURL, options: .atomic)
            }
            self.trimLogFileIfNeeded()
        }
    }

    func clear() {
        queue.async {
            try? "".write(to: self.logURL, atomically: true, encoding: .utf8)
            self.estimatedLineCount = 0
        }
    }

    /// 累積寫入位元組（供 DeviceInfo 取樣）
    private(set) var totalWrittenBytes: UInt64 = 0

    private func write(_ data: Data) {
        let newLines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        estimatedLineCount += newLines
        totalWrittenBytes += UInt64(data.count)

        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: logURL, options: .atomic)
        }

        if estimatedLineCount > maxLogFileLines + trimMargin && !trimScheduled {
            trimScheduled = true
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.trimLogFileIfNeeded()
                self?.trimScheduled = false
            }
        }
    }

    private func trimLogFileIfNeeded() {
        guard let handle = try? FileHandle(forReadingFrom: logURL),
              let currentData = try? handle.readToEnd()
        else { return }
        handle.closeFile()
        guard let content = String(data: currentData, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)

        estimatedLineCount = lines.count

        guard lines.count > maxLogFileLines else { return }

        let trimmedLines = lines.suffix(maxLogFileLines)
        let trimmedText = trimmedLines.joined(separator: "\n") + "\n"
        try? trimmedText.write(to: logURL, atomically: true, encoding: .utf8)
        estimatedLineCount = maxLogFileLines
    }
}


// MARK: 新日誌區塊
final class LogModel: ObservableObject {

    @Published private(set) var messages: [LogItem] = []

    let newMessages = PassthroughSubject<[LogItem], Never>()

    let queue = DispatchQueue(label: "liveApp.logModel")


    /// UI 更新頻率（秒）
    private let refreshInterval: TimeInterval = 0.1
    /// 每次最多吃幾筆 log
    private let batchLimit = 100
    /// Buffer安全大下
    private let maxMessages = 1000

    init() {

        LogBuffer.shared.onNewLog = { [weak self] logs in

            guard let self else { return }
            let items = logs.map { LogItem(message: $0) }
            self.messages.append(contentsOf: items)
            if self.messages.count > self.maxMessages * 2 {
                self.messages.removeFirst(self.messages.count - self.maxMessages)
            }
            self.newMessages.send(items)

        }

    }


   


    func clearLogs() {
        messages.removeAll()

        LogBuffer.shared.clear()
    }

    deinit {
        clearLogs()
        os_log("LogModel釋放緩衝區")
        
    }
}


final class LogReceiver {
    private let maxPush = 50

    private let groupID = "group.nuclear.liveAPP"
    private let logFileName = "log.txt"

    private let bufferQueue = DispatchQueue(label: "com.nuclear.LogReceiver.bufferQueue")

    private var lastReadOffset: UInt64 = 0
    private var buffer: [String] = []

    private let flushDebounce: TimeInterval = 0.2
    private var flushWorkItem: DispatchWorkItem?


    init() {
        // 讀取上次儲存 offset

        lastReadOffset = UInt64(userDefaults?.integer(forKey: "lastReadOffset") ?? 0)

        // 註冊 Darwin 通知
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            LogReceiver.notificationCallback,
            "liveAPP.log" as CFString,
            nil,
            .deliverImmediately
        )




    }

    deinit {


        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            CFNotificationName("liveAPP.log" as CFString),
            nil
        )

    }

    // MARK: - C callback
    private static let notificationCallback: CFNotificationCallback = { _, observer, _, _, _ in
        guard let observer else { return }

        let mySelf = Unmanaged<LogReceiver>.fromOpaque(observer).takeUnretainedValue()

        mySelf.readNewLines()

    }

    // MARK: - 讀新增 log
    private func readNewLines() {

        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            sendlog(message:"❌ LogReceiver: 無法取得 containerURL")
            return
        }
        let fileURL = containerURL.appendingPathComponent(logFileName)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            // open file
            guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
                sendlog(message:"❌ LogReceiver: 無法打開檔案 \(fileURL.path)")
                return
            }
            defer { try? fileHandle.close() }


            do {
                let fileSize = try fileHandle.seekToEnd()

                if self.lastReadOffset > fileSize {
                    self.lastReadOffset = fileSize // 重新校正 offset
                    sendlog(message:"lastRead \(self.lastReadOffset) fileSize:\(fileSize)")
                }

            } catch {
                sendlog(message: "Error seekToEnd: \(error)")
            }

            // seek 到上次 offset
            do {
                try fileHandle.seek(toOffset: self.lastReadOffset)
            } catch {
                sendlog(message:"❌ LogReceiver: seek 失敗, offset: \(self.lastReadOffset), error: \(error)")
                return
            }


            // 讀取新增資料
            let data = fileHandle.readDataToEndOfFile()

            guard !data.isEmpty else {
                sendlog(message:"LogReceiver: lastReadOffset = \(self.lastReadOffset), fileSize = \(fileHandle.seekToEndOfFile())")
                sendlog(message:"⚠️ LogReceiver: 無新增資料可讀")
                return
            }

            // 轉成字串
            guard let content = String(data: data, encoding: .utf8) else {
                sendlog(message:"❌ LogReceiver: 讀取資料編碼失敗")
                return
            }


            let normalizedContent = content
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .split(separator: "\n")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

            let lines = Array(normalizedContent)


            guard !lines.isEmpty else {
                sendlog(message:"⚠️ LogReceiver: 讀取到的資料沒有換行符號")
                return
            }


            // 限制推送行數
            let newLines = Array(lines.suffix(self.maxPush))

            // 讀取新的 lines
            bufferQueue.async {

                self.buffer.append(contentsOf: newLines)

                // 更新 offset
                self.lastReadOffset += UInt64(data.count)

                // 短暫延遲 flush（debounce）
                self.flushWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    self?.flushBuffer()
                }
                self.flushWorkItem = workItem
                self.bufferQueue.asyncAfter(deadline: .now() + self.flushDebounce, execute: workItem)


            }





        }
    }

    // MARK: - 批次推送 buffer
    private func flushBuffer() {


            guard !self.buffer.isEmpty else { return }
            let linesToSend = self.buffer

            self.buffer.removeAll()

            LogBuffer.shared.push(linesToSend)
            AppLogPersister.shared.append(lines: linesToSend)

            // ✅ 批次更新 offset，降低 UserDefaults I/O
            userDefaults?.set(Int(lastReadOffset), forKey: "lastReadOffset")





        

    }
}



// MARK: RemoteLog
final class RemoteLogBuffer {
    static let shared = RemoteLogBuffer()

    private let queue = DispatchQueue(label: "remote.log.buffer.queue")
    private var buffer: [[String: String]] = []

    /// 最多暫存幾筆，超過就丟
    private let maxBufferSize = 500

    func push(title: String, message: String) {
        let item = [
            "title": title,
            "body": message,
            "time": formatTime()
        ]

        queue.async {
            self.buffer.append(item)
            if self.buffer.count > self.maxBufferSize {
                let excess = self.buffer.count - self.maxBufferSize
                self.buffer.removeFirst(excess)
                logger.debug("⚠️ RemoteLogBuffer 已滿，丟棄 \(excess) 條最舊日誌")
            }
        }
    }

    func drain(max: Int) -> [[String: String]] {
        queue.sync {
            guard !buffer.isEmpty else { return [] }
            let count = min(max, buffer.count)
            let result = Array(buffer.prefix(count))
            buffer.removeFirst(count)
            return result
        }
    }
}

// MARK: RemoteLogSend
final class RemoteLogSender {

    static let shared = RemoteLogSender()

    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "RemoteLogSenderTimerQueue", qos: .utility)
    private let session = URLSession(configuration: .ephemeral)

    private let flushInterval: TimeInterval = 1.0
    private let batchLimit = 150

    private var started = false


    func stop() {
        timerQueue.async { [weak self] in
            guard let self, self.started else { return }
            self.timer?.cancel()
            self.timer = nil
            self.started = false
        }
    }

    func start() {
        timerQueue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true

            let t = DispatchSource.makeTimerSource(queue: self.timerQueue)
            t.schedule(deadline: .now() + self.flushInterval, repeating: self.flushInterval)
            t.setEventHandler { [weak self] in
                self?.flush()
            }
            self.timer = t
            t.resume()
        }
    }

    private func flush() {
        let logs = RemoteLogBuffer.shared.drain(max: batchLimit)
        guard !logs.isEmpty else { return }

        sendBatch(logs)
    }

    private func sendBatch(_ logs: [[String: String]]) {
        let urla = LPConfig.shared.logURL
        guard let url = URL(string: urla) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "logs": logs
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        request.httpBody = body

        session.dataTask(with: request) { _, _, _ in
            // 失敗直接忽略（log 本來就不重要）
        }.resume()
    }

    deinit {
        timerQueue.sync {
            timer?.cancel()
            timer = nil
            started = false
        }
    }
}

func remotelog(title:String="liveApp",message:String) {

    let urla = LPConfig.shared.logURL
    guard let url = URL(string: urla) else {
        print("❌ URL 無效")
        return
    }

    // 2. 準備 URLRequest
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let timeString = formatTime()

    // 3. JSON 資料
    let json: [String: Any] = [
        "title":title,
        "body":message,
        "time":timeString
    ]

    guard let httpBody = try? JSONSerialization.data(withJSONObject: json, options: []) else {
        print("❌ JSON 轉換失敗")
        return
    }
    request.httpBody = httpBody

    // 4. 發送請求
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        if let error = error {
            print("❌ 發送失敗:", error)
            return
        }

        if let data = data,
           let responseString = String(data: data, encoding: .utf8) {
            print("✅ 收到回應:", responseString)
        }
    }

    task.resume()
}


// 全局共用時間 liveApp格式器
struct StaticFormatter {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_TW")
        f.dateFormat = "yyyy/MM/dd aHH:mm:ss.SSS"
        return f
    }()
}

func formatTime() -> String {
    let formatter = StaticFormatter.formatter
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    formatter.locale = Locale.current

    let now = Date()
    let timeString = formatter.string(from: now)

    return timeString

}


// MARK: 日誌通知
func sendlog(title:String = "liveApp",message: String) {

    guard LPConfig.shared.enableLog else { return }

    let timeString = formatTime()
    let full = "\(timeString): \(title):\(message)"

    // MARK: 日誌緩衝區
    LogBuffer.shared.push(full)
    AppLogPersister.shared.append(line: full)

    // 遠端 log 可以保留（但最好也 async）
    if LPConfig.shared.logMode == 0 || LPConfig.shared.logMode == 2 {

        RemoteLogSender.shared.start()
        RemoteLogBuffer.shared.push(title: title, message: message)

    } else {
        // 取消遠端 log
        RemoteLogSender.shared.stop()

    }

    logger.info("logMode:\(LPConfig.shared.logMode) \(title,privacy:.public):\(message,privacy:.public)")




}

func receiveSocketLog(title: String = "UseESocket", message: String) {
    guard LPConfig.shared.enableLog || LPConfig.shared.SocketLog else { return }

    //let timeString = formatTime()
    // 已經有時間戳了，避免重複

    let lines = message
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { "\(title):\($0)" }

    if lines.isEmpty {
        
        LogBuffer.shared.push("\(title):\(message)")


        AppLogPersister.shared.append(line: "\(title):\(message)")
    } else {
        LogBuffer.shared.push(lines)
        AppLogPersister.shared.append(lines: lines)
    }

    if LPConfig.shared.logMode == 0 || LPConfig.shared.logMode == 2 {
        RemoteLogSender.shared.start()
        RemoteLogBuffer.shared.push(title: title, message: message)
    }
}








#if os(iOS)
func showLogOnScreen(_ message: String) {
    DispatchQueue.main.async {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }

        let alert = UIAlertController(title: "Log", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        rootVC.present(alert, animated: true)
    }
}

#endif

func postSystemNotification(title: String, body: String, imageURL: String? = nil) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.categoryIdentifier = "replykit_notification"

    if let imageURL = imageURL, let url = URL(string: imageURL) {
        // 下載遠端圖片並存到暫存，再建立附件
        URLSession.shared.dataTask(with: url) { data, _, error in
            if let data = data, error == nil {
                let tempDir = FileManager.default.temporaryDirectory
                let tempFile = tempDir.appendingPathComponent(UUID().uuidString + ".png")
                try? data.write(to: tempFile)
                if let attachment = try? UNNotificationAttachment(identifier: "image", url: tempFile, options: nil) {
                    content.attachments = [attachment]
                }
            }
            // 不論圖片是否下載成功，都發送通知
            deliverNotification(content: content)
        }.resume()
    } else {
        deliverNotification(content: content)
    }
}

private func deliverNotification(content: UNMutableNotificationContent) {
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
    let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: trigger
    )
    UNUserNotificationCenter.current().add(request) { error in
        if let error = error {
            print("❌ 發送通知失敗: \(error)")
        } else {
            print("✅ 通知已發送")
        }
    }
}




//final class SocketUserDefaluts: ObservableObject {
//    @Published var server: CFMessagePortServer?
//
//    static let shared = SocketUserDefaluts()
//
//    private init() {}
//
//
//    func startSettingsServer() {
//        guard server == nil else { return } // 避免重複啟動
//        
//        server = CFMessagePortServer.shared
//
//        server?.start()
//
//
////            NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
////                guard let self = self else { return }
////                let defaults = UserDefaults.standard
////                for (key, value) in defaults.dictionaryRepresentation() {
////                    self.server?.broadcast(key: key, value: value)
////                }
////            }
////        } catch {
////            print("Failed to start SettingsServer: \(error)")
////        }
//    }
//}
//

@main
struct liveAPPApp: App {
    // 建立 delegate 實例
    let notificationDelegate = NotificationDelegate()

    @StateObject var logModel = LogModel()



    enum OrientationCategory {
        case portrait
        case landscape
        case unknown
    }








    init() {

        // App 啟動時就啟動 Socket Server
        // 啟動一次


        if LPConfig.shared.SocketLog  {

            sendlog(message: "已啟用Socket轉送 不依賴日誌文件變動監聽")

        } else {
            sendlog(message: "已停用Socket轉送 使用日誌文件變動監聽")

            SharedResources.shared.setupLogReceiver()

        }

        SocketServer.shared.start()

        // 註冊 BGTaskScheduler 處理常式
        BackgroundTaskManager.shared.registerTasks()

        // 將 App Group 既有的 log 複製到 Documents/ 供檔案 App 讀取
        AppLogPersister.shared.copyFromAppGroup()

        // MARK: - 記憶體壓力監聽
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in

            sendlog(message: "⚠️ 收到 Memory Warning")

            // PiP 分級釋放（內部依 warning 次數遞增釋放力度）
            PIPService.shared.handleMemoryWarning()

            // 只釋放 Socket 閒置 buffer（輕量）
            SocketServer.shared.releaseMemory()
        }
        #endif



#if os(iOS)

        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                if granted {
                    print("麥克風權限允許")
                    // 可以啟動 ReplayKit 或推流
                } else {
                    print("麥克風權限拒絕")
                    // 提示用戶去設定裡開啟
                }
            }
        }
#elseif os(macOS)

AVCaptureDevice.requestAccess(for: .audio) { granted in
    DispatchQueue.main.async {
        if granted {
            print("麥克風權限允許")
            // 可以啟動錄音或推流
        } else {
            print("麥克風權限拒絕")
            // 提示用戶去設定裡開啟
        }
    }
}
        #endif



        // 註冊 delegate
        UNUserNotificationCenter.current().delegate = notificationDelegate

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("✅ 通知授權已取得")
            } else if let error = error {
                print("❌ 通知授權錯誤: \(error)")
            }
        }

        let category = UNNotificationCategory(
            identifier: "replykit_notification",
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])

        Task { @MainActor in
            TTSService.shared.refreshAudioSessionForCurrentSetting()
        }


    }


    

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(logModel)
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .inactive:
                        break

                    case .background:
                        sendlog(message: "App 進入背景，啟動短背景視窗並排程 Socket refresh")

                        // 通知 PIPService 進入背景
                        PIPService.shared.appDidEnterBackground()

                        // 釋放非關鍵記憶體，降低被 kill 風險
                        PIPService.shared.releaseNonCriticalMemory()
                        logModel.clearLogs()

                        // beginBackgroundTask 只能提供短時間背景窗口；BGTaskScheduler 是機會型 refresh，不保證常駐。
                        #if os(iOS)
                        BackgroundTaskManager.shared.beginSocketBackgroundWindow()
                        BackgroundTaskManager.shared.scheduleSocketRefresh()
                        #endif

                    case .active:
                        sendlog(message: "App 回到前景")
                        SocketServer.shared.start()

                        // 通知 PIPService 回到前景
                        PIPService.shared.appWillEnterForeground()

                        // 取消背景窗口與 BGTaskScheduler 任務（前景不需要）
                        #if os(iOS)
                        BackgroundTaskManager.shared.cancelAll()
                        #endif

                    @unknown default:
                        break
                    }
                }


        }
    }
}



class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}


#if os(iOS)
extension UIDeviceOrientation {
    func matches(_ interfaceOrientation: UIInterfaceOrientation) -> Bool {
        switch (self, interfaceOrientation) {
        case (.portrait, .portrait), (.portraitUpsideDown, .portraitUpsideDown),
             (.landscapeLeft, .landscapeRight), (.landscapeRight, .landscapeLeft):
            return true
        default:
            return false
        }
    }
}

#endif

