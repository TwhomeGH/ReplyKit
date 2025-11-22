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

// ObservableObject 接收 Notification
final class LogModel: ObservableObject {
    @Published private(set) var messages: [LogItem] = []
    private var cancellable: AnyCancellable?
    private var buffer: [LogItem] = []
    private var timer: Timer?

    init() {
        // 批次更新 UI，每 0.3 秒
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self = self, !self.buffer.isEmpty else { return }
            let newItems = self.buffer
            self.buffer.removeAll()
            DispatchQueue.main.async {
                self.messages.append(contentsOf: newItems)
                if self.messages.count > 200 {
                    self.messages.removeFirst(self.messages.count - 200)
                }
            }
        }

        // 收通知
        cancellable = NotificationCenter.default.publisher(for: .appLogNotification)
            .compactMap { $0.object as? String }
            .sink { [weak self] msg in
                self?.buffer.append(LogItem(message: msg))
            }
    }

    func clearLogs() {
        DispatchQueue.main.async {
            self.messages.removeAll()
        }
    }

    deinit {
        timer?.invalidate()
    }
}

final class LogReceiver {
    private let maxPush = 20
    private let flushInterval: TimeInterval = 0.3
    private let groupID = "group.nuclear.liveAPP"
    private let logFileName = "log.txt"

    private var lastReadOffset: UInt64 = 0
    private var buffer: [String] = []
    private var timer: Timer?

    init() {
        // 讀取上次儲存 offset
        lastReadOffset = UInt64(UserDefaults.standard.integer(forKey: "lastReadOffset"))

        // 註冊 Darwin 通知
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            LogReceiver.notificationCallback,
            "liveAPP.log" as CFString,
            nil,
            .deliverImmediately
        )

        // Timer 批次發送 buffer
        timer = Timer.scheduledTimer(withTimeInterval: flushInterval, repeats: true) { [weak self] _ in
            self?.flushBuffer()
        }
    }

    deinit {
        timer?.invalidate()
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

            let lines = content.split(separator: "\n").map { String($0) }
            if !lines.isEmpty {
                // 限制推送行數
                let newLines = lines.suffix(self.maxPush)
                self.buffer.append(contentsOf: newLines)
            }else {
                sendlog(message:"⚠️ LogReceiver: 讀取到的資料沒有換行符號")
            }

            // 更新 offset
            self.lastReadOffset += UInt64(data.count)
            UserDefaults.standard.set(Int(self.lastReadOffset), forKey: "lastReadOffset")
        }
    }

    // MARK: - 批次推送 buffer
    private func flushBuffer() {
        guard !buffer.isEmpty else { return }
        let linesToSend = buffer
        buffer.removeAll()

        DispatchQueue.main.async {
            for line in linesToSend {
                NotificationCenter.default.post(name: .appLogNotification, object: line)
            }
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


func formatTime() -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    formatter.locale = Locale.current

    let now = Date()
    let timeString = formatter.string(from: now)

    return timeString

}
func sendlog(title:String = "liveApp",message: String) {
    // 1. 目標 URL

    let Enablelog:Bool = LPConfig.shared.enableLog
    let mode2:Int = LPConfig.shared.logMode
    let timeString = formatTime()


    logger.info("EnableLog:\(Enablelog)")
    if Enablelog {
        switch mode2 {

            case 0:
            remotelog(title:title,message: message)

            case 1:
                NotificationCenter.default.post(name: .appLogNotification, object: "\(timeString): \(title):\(message)")
            case 2:
            NotificationCenter.default.post(name: .appLogNotification, object: "\(timeString): \(title):\(message)")
            remotelog(title:title,message: message)

            default:
                NotificationCenter.default.post(name: .appLogNotification, object: "\(timeString): \(title):\(message)")

        }


    }



    logger.info("logMode:\(mode2) \(title,privacy:.public):\(message,privacy:.public)")


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

func postSystemNotification(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default

    // 立即觸發
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
            print("\(body)")
            print("✅ 通知已發送")
        }
    }
}




final class SocketUserDefaluts: ObservableObject {
    @Published var server: SocketServer?

    static let shared = SocketUserDefaluts()

    private init() {}


    func startSettingsServer() {
        guard server == nil else { return } // 避免重複啟動


        do {
            server = try SocketServer()
            NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                let defaults = UserDefaults.standard
                for (key, value) in defaults.dictionaryRepresentation() {
                    self.server?.broadcast(key: key, value: value)
                }
            }
        } catch {
            print("Failed to start SettingsServer: \(error)")
        }
    }
}

@main
struct liveAPPApp: App {
    // 建立 delegate 實例
    let notificationDelegate = NotificationDelegate()

    @StateObject var logModel = LogModel()
    let logReceiver = LogReceiver()


    #if os(iOS)
    func cacheInitialOrientation() {
        let deviceOrientation = UIDevice.current.orientation
        guard deviceOrientation != .faceUp,
              deviceOrientation != .faceDown,
              deviceOrientation != .unknown else { return }


        // 明確使用 App Group
        let userDefaults = UserDefaults(suiteName: "group.nuclear.liveAPP")

        userDefaults?.set(deviceOrientation.rawValue, forKey: "LOrientation")
        userDefaults?.set(false, forKey: "LockIN")
       


        let g=userDefaults?.integer(forKey: "LOrientation") ?? 1
        let g2=userDefaults?.bool(forKey: "LockIN") ?? false
        print("DGG",g,g2)
    }
    #else
    func cacheInitialOrientation() {
        print("not make this!!")
    }
#endif






    enum OrientationCategory {
        case portrait
        case landscape
        case unknown
    }




    #if os(iOS)
    func startMonitoringOrientation() {
        print("事件註冊")
        StableLockRotationDetector.shared.debugMode=true
        StableLockRotationDetector.shared.onLockStateDetected = { isLocked in

            // 明確使用 App Group
            let userDefaults = UserDefaults(suiteName: "group.nuclear.liveAPP")

            if isLocked {

                
                userDefaults?.set(true, forKey: "LockIN")

                let cfCenter = CFNotificationCenterGetDarwinNotifyCenter()


                CFNotificationCenterPostNotification(cfCenter,
                                                     CFNotificationName("orientationChanged" as CFString),
                                                     nil, nil, true)

                print("使用者可能開了螢幕鎖定 🔒")
            } else {
                userDefaults?.set(false, forKey: "LockIN")


                let cfCenter = CFNotificationCenterGetDarwinNotifyCenter()

                CFNotificationCenterPostNotification(cfCenter,
                                                     CFNotificationName("orientationChanged" as CFString),
                                                     nil, nil, true)

                print("螢幕方向自由旋轉 ✅")
            }
        }

        StableLockRotationDetector.shared.startMonitoring(interval: 0.5)
    }
#else
    func startMonitoringOrientation() {
        print("Not make!!")
    }
    #endif





    init(){

        // App 啟動時就啟動 Socket Server
        // 啟動一次
        SocketUserDefaluts.shared.startSettingsServer()

        cacheInitialOrientation()


        UserDefaults.standard.set(0, forKey: "lastReadLineCount")




       

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
    }




    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(logModel)

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

