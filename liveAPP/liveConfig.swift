//
//  liveConfig.swift
//  liveAPP
//
//  Created by user on 2025/11/2.
//

import os
import Foundation

final class SharedResources {
    static let shared = SharedResources()

    private(set) var logReceiver: LogReceiver?
    private let groupID = "group.nuclear.liveAPP"

    private init() {}

    // 嘗試建立 LogReceiver
    func setupLogReceiver() {
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil {
            if logReceiver == nil {
                logReceiver = LogReceiver()
                sendlog(message:"✅ LogReceiver 已建立")
            }
        } else {
            sendlog(message:"⚠️ App Group 無效，不建立 LogReceiver")
            logReceiver = nil
        }
    }

    // 主動釋放 LogReceiver
    func releaseLogReceiver() {
        logReceiver = nil
        sendlog(message:"🗑 LogReceiver 已釋放")
    }
}


final class LPConfig {
    static let shared = LPConfig()

    // TTS相關
    

    // 日誌相關
    var enableLog: Bool = false
    var logMode: Int = 1
    var onLogPage: Bool = false
    var logURL:String = "http://192.168.0.242:3000/post"

    // 其他配置
    var maxInflightFrames: Int = 4

    var FadeAlpha:Double
    var MessageFadeTime:Double
    var ScrollTime:Double

    var StreamEnded: Bool = false
    var StreamEndMes:String = ""
    var streamViewerCount: Int?
    var streamViewerList: [String] = []
    var streamBitrate: String = ""

    // 上一場直播時長
    var lastStreamTime:Double = 0.0

    var streamStartTime: Date?

    // MARK: 重連狀態
    var isReconnecting = false
    var reconnectAttempt = 0
    var reconnectMaxAttempts = 5
    var reconnectStatus: String = ""


    var PIPChatFontMainSize: Double = 14.0
    var PIPChatFontSecondSize: Double = 10.0
    var PIPAdOverlayFontSize: Double = 13.0
    var PIPAdOverlayUserFontSize: Double = 14.0
    var PIPAdOverlaySpacing: Double = 4.5
    var PIPAdOverlayDuration: Double = 5.0

    var PIPLog: Bool = false
    var PIPChatLog:Bool = false
    
    var SocketLog:Bool = false

    static var isSideload: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.nuclear.liveAPP") == nil
    }

    private init() {



        PIPLog = userDefaults?.bool(forKey: "PIPLog") ?? false
        PIPChatLog = userDefaults?.bool(forKey: "PIPChatLog") ?? false


        logMode=userDefaults?.integer(forKey: "logMode") ?? 0
        onLogPage=userDefaults?.bool(forKey: "onlogPage") ?? false
        enableLog=userDefaults?.bool(forKey: "Enablelog") ?? false
        logURL = userDefaults?.string(forKey: "logURL") ?? "http://192.168.0.242:3000/post"
        
        SocketLog = userDefaults?.bool(forKey: "EnableSocketlog") ?? false
        if Self.isSideload {
            SocketLog = true
        }

        FadeAlpha = userDefaults?.double(forKey: "fadeAlpha") ?? 0.08

        ScrollTime = userDefaults?.double(forKey: "scrollTime") ?? 0.2
        MessageFadeTime =  userDefaults?.double(forKey: "fadeTime") ?? 0.5

        PIPChatFontMainSize = userDefaults?.double(forKey: "PIPFontMain") ?? 14.0
        PIPChatFontSecondSize =  userDefaults?
            .double(forKey: "PIPFontSecond") ?? 10.0
        PIPAdOverlayFontSize = (userDefaults?.object(forKey: "PIPAdOverlayFont") as? Double) ?? 13.0
        PIPAdOverlayUserFontSize = (userDefaults?.object(forKey: "PIPAdOverlayUserFont") as? Double) ?? 14.0
        PIPAdOverlaySpacing = (userDefaults?.object(forKey: "PIPAdOverlaySpacing") as? Double) ?? 4.5
        PIPAdOverlayDuration = (userDefaults?.object(forKey: "PIPAdOverlayDuration") as? Double) ?? 5.0

    }


}
