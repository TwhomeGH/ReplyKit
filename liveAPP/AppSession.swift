import Foundation

/// 單次程序啟動的身分與時間；供診斷匯出從本次啟動開始篩選。
enum AppSession {
    static let launchDate = Date()
    static let launchID = UUID().uuidString

    private static let lastForegroundStartKey = "AppSession.lastForegroundStart"
    private static let lastForegroundEndKey = "AppSession.lastForegroundEnd"
    private static var activeStartedAt: Date?

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
}
