//
//  liveConfig.swift
//  liveAPP
//
//  Created by user on 2025/11/2.
//



final class LPConfig {
    static let shared = LPConfig()

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
