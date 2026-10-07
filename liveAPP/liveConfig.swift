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

// MARK: - LPConfig
/// 直播配置與全局狀態管理
final class LPConfig {
    static let shared = LPConfig()

    
    // MARK: - 日誌相關

    /// 是否啟用日誌功能
    var enableLog: Bool = false
    /// 日誌模式，0: 不啟用，1: 本地日誌，2: 遠端日誌
    var logMode: Int = 1
    /// 是否在日誌頁面中
    /// 此屬性用於追蹤應用是否處於日誌頁面，以便在後台狀態下決定是否繼續更新日誌。
    /// 注意: 此屬性可能存在疑慮應考慮棄用或重構，因為它可能會導致在後台狀態下仍然更新日誌頁面，這可能不是預期的行為。
    var onLogPage: Bool = false
    /// 遠端日誌伺服器 URL
    var logURL:String = "http://192.168.0.242:3000/post"

    // MARK: - 直播相關

    /// 直播碼率限制，最大同時處理的幀數
    var maxInflightFrames: Int = 5

    // MARK: - PIP 與訊息相關
    
    /// PIP 淡入淡出透明度
    var FadeAlpha:Double
    /// 訊息淡出時間
    var MessageFadeTime:Double
    /// 滾動時間
    var ScrollTime:Double

    // MARK: - 直播狀態相關

    /// 直播是否已結束
    var StreamEnded: Bool = false
    
    /// 直播結束訊息
    var StreamEndMes:String = ""
    
    /// 直播觀眾人數
    var streamViewerCount: Int?
    
    /// 直播觀眾列表
    var streamViewerList: [String] = []
    
    /// 直播位元速率
    /// 此屬性用於追蹤直播的位元速率，可能會在直播過程中動態更新。
    /// 注意: 此屬性設計應考慮其在多線程環境下的安全性，可能需要使用同步機制來保護對此屬性的訪問。
    /// 此屬性可能是給即時動態監控使用，應考慮其更新頻率與性能影響。
    var streamBitrate: String = ""

    /// 上一場直播時長
    var lastStreamTime:Double = 0.0

    /// 直播開始時間
    var streamStartTime: Date?

    // MARK: 重連狀態

    /// 是否正在進行重連
    var isReconnecting = false
    
    /// 重連嘗試次數
    var reconnectAttempt = 0
    
    /// 最大重連嘗試次數
    var reconnectMaxAttempts = 5

    /// 重連狀態訊息，用於顯示當前的重連狀態，例如 "正在重連..." 或 "重連失敗"。
    var reconnectStatus: String = ""

    // MARK: - PIP 與訊息相關

    /// PIP 聊天訊息主字體大小
    var PIPChatFontMainSize: Double = 14.0
    /// PIP 聊天訊息副字體大小

    var PIPChatFontSecondSize: Double = 10.0
    /// PIP 廣告覆蓋字體大小
    var PIPAdOverlayFontSize: Double = 13.0
    /// PIP 廣告覆蓋使用者字體大小
    var PIPAdOverlayUserFontSize: Double = 14.0
    /// PIP 廣告覆蓋間距
    var PIPAdOverlaySpacing: Double = 4.5
    /// PIP 廣告覆蓋持續時間
    var PIPAdOverlayDuration: Double = 5.0

    /// PIP 當前時間標籤
    var PIPNowTimeLabel: String = AppLanguage.localized("pip.default.nowTimeLabel")
    /// PIP 直播標籤
    var PIPLiveLabel: String = AppLanguage.localized("pip.default.liveLabel")
    /// PIP 結束標籤
    var PIPEndedLabel: String = AppLanguage.localized("pip.default.endedLabel")

    /// PIP 日誌功能
    var PIPLog: Bool = false
    /// PIP 聊天日誌功能
    var PIPChatLog:Bool = false
    /// Socket 日誌功能
    var SocketLog:Bool = false

    /// 檢查應用是否為側載版本
    static var isSideload: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.nuclear.liveAPP") == nil
    }

    /// 初始化 LPConfig，從 UserDefaults 中讀取配置值，若不存在則使用預設值。
    /// 此初始化方法設計應考慮其在多線程環境下的安全性，可能需要使用同步機制來保護對 UserDefaults 的訪問。
    private init() {


        // 從 UserDefaults 中讀取配置值，若不存在則使用預設值
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

        FadeAlpha = userDefaults?.object(forKey: "fadeAlpha") as? Double ?? 0.08

        ScrollTime = userDefaults?.object(forKey: "scrollTime") as? Double ?? 0.2
        MessageFadeTime =  userDefaults?.object(forKey: "fadeTime") as? Double ?? 0.5

        PIPChatFontMainSize = userDefaults?.object(forKey: "PIPFontMain") as? Double ?? 14.0
        PIPChatFontSecondSize =  userDefaults?
            .object(forKey: "PIPFontSecond") as? Double ?? 10.0
            
        PIPAdOverlayFontSize = (userDefaults?.object(forKey: "PIPAdOverlayFont") as? Double) ?? 13.0
        PIPAdOverlayUserFontSize = (userDefaults?.object(forKey: "PIPAdOverlayUserFont") as? Double) ?? 14.0
        PIPAdOverlaySpacing = (userDefaults?.object(forKey: "PIPAdOverlaySpacing") as? Double) ?? 4.5
        PIPAdOverlayDuration = (userDefaults?.object(forKey: "PIPAdOverlayDuration") as? Double) ?? 5.0
        PIPNowTimeLabel = Self.localizedOverride(
            key: "PIPNowTimeLabelOverride",
            localizedKey: "pip.default.nowTimeLabel"
        )
        PIPLiveLabel = Self.localizedOverride(
            key: "PIPLiveLabelOverride",
            localizedKey: "pip.default.liveLabel"
        )
        PIPEndedLabel = Self.localizedOverride(
            key: "PIPEndedLabelOverride",
            localizedKey: "pip.default.endedLabel"
        )

    }

    /// 根據指定的鍵和本地化鍵返回覆蓋的本地化字符串。
    /// 如果在 UserDefaults 中找不到對應的覆蓋值，則返回對應的本地化字符串。
    /// 此方法設計應考慮其在多線程環境下的安全性，可能需要使用同步機制來保護對 UserDefaults 的訪問。
    private static func localizedOverride(key: String, localizedKey: String) -> String {
        let override = userDefaults?.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return override.isEmpty ? AppLanguage.localized(localizedKey) : String(override.prefix(12))
    }


}
