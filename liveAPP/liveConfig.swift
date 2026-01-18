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

    // 日誌相關
    var enableLog: Bool = false
    var logMode: Int = 1
    var onLogPage: Bool = false
    var logURL:String = "http://192.168.0.242:3000/post"

    // 其他配置
    var maxInflightFrames: Int = 4

    var StreamEnded: Bool = false
    var StreamEndMes:String = ""
    
    var streamStartTime: Date?


    var PIPLog: Bool = false
    var PIPChatLog:Bool = false

    var SocketLog:Bool = false


    private init() {

        PIPLog = userDefaults?.bool(forKey: "PIPLog") ?? false
        PIPChatLog = userDefaults?.bool(forKey: "PIPChatLog") ?? false


        logMode=userDefaults?.integer(forKey: "logMode") ?? 0
        onLogPage=userDefaults?.bool(forKey: "onlogPage") ?? false
        enableLog=userDefaults?.bool(forKey: "Enablelog") ?? false
        logURL = userDefaults?.string(forKey: "logURL") ?? "http://192.168.0.242:3000/post"
        SocketLog = userDefaults?.bool(forKey: "EnableSocketlog") ?? false

    }


}
