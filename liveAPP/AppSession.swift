import Foundation

/// 單次程序啟動的身分與時間；供診斷匯出從本次啟動開始篩選。
enum AppSession {
    static let launchDate = Date()
    static let launchID = UUID().uuidString

    private static let lastForegroundStartKey = "AppSession.lastForegroundStart"
    private static let lastForegroundEndKey = "AppSession.lastForegroundEnd"
    private static let lastStreamStartKey = "AppSession.lastStreamStart"
    private static let lastStreamEndKey = "AppSession.lastStreamEnd"
    private static var activeStartedAt: Date?
    private static var activeStreamStartedAt: Date?

    static func markLaunch() {
        sendlog(message: "[AppSession] launch id=\(launchID) startedAt=\(launchDate.timeIntervalSince1970)")
    }

    /// 前景 active 開始；同一段 active 內重複呼叫不覆寫起點。
    static func markActive() {
        guard activeStartedAt == nil else { return }
        activeStartedAt = Date()
    }

    /// 進背景時保存「最後一次前景 active → 背景」區間，跨程序仍可用於診斷匯出。
    static func markBackground() {
        guard let start = activeStartedAt else { return }
        let end = Date()
        activeStartedAt = nil
        guard end > start else { return }
        let defaults = UserDefaults.standard
        defaults.set(start.timeIntervalSince1970, forKey: lastForegroundStartKey)
        defaults.set(end.timeIntervalSince1970, forKey: lastForegroundEndKey)
        sendlog(message: "[AppSession] foreground interval start=\(start.timeIntervalSince1970) end=\(end.timeIntervalSince1970)")
    }

    /// 目前前景 active 的起點；已進背景或程序尚未 active 時為 nil。
    static var currentForegroundStartedAt: Date? { activeStartedAt }

    /// 最近一次已完成的前景 active 區間；沒有背景事件時為 nil。
    static var lastForegroundInterval: DateInterval? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: lastForegroundStartKey) != nil,
              defaults.object(forKey: lastForegroundEndKey) != nil else { return nil }
        let start = Date(timeIntervalSince1970: defaults.double(forKey: lastForegroundStartKey))
        let end = Date(timeIntervalSince1970: defaults.double(forKey: lastForegroundEndKey))
        guard end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// 開播時記錄起點；重複呼叫不覆寫，避免 Live Activity 重啟把範圍往後推。
    static func markStreamStart() {
        guard activeStreamStartedAt == nil else { return }
        let start = Date()
        activeStreamStartedAt = start
        sendlog(message: "[AppSession] streamStart startedAt=\(start.timeIntervalSince1970)")
    }

    /// 停播時保存完整推流區間，供「上次推流」診斷匯出使用。
    static func markStreamEnd() {
        guard let start = activeStreamStartedAt else { return }
        let end = Date()
        activeStreamStartedAt = nil
        guard end > start else { return }
        let defaults = UserDefaults.standard
        defaults.set(start.timeIntervalSince1970, forKey: lastStreamStartKey)
        defaults.set(end.timeIntervalSince1970, forKey: lastStreamEndKey)
        sendlog(message: "[AppSession] stream interval start=\(start.timeIntervalSince1970) end=\(end.timeIntervalSince1970)")
    }

    /// 本次推流的起點；目前沒有推流時為 nil。
    static var currentStreamStartedAt: Date? { activeStreamStartedAt }

    /// 上一次已完成推流的區間；從未完成推流時為 nil。
    static var lastStreamInterval: DateInterval? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: lastStreamStartKey) != nil,
              defaults.object(forKey: lastStreamEndKey) != nil else { return nil }
        let start = Date(timeIntervalSince1970: defaults.double(forKey: lastStreamStartKey))
        let end = Date(timeIntervalSince1970: defaults.double(forKey: lastStreamEndKey))
        guard end > start else { return nil }
        return DateInterval(start: start, end: end)
    }
}
