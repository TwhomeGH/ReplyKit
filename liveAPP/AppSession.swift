import Foundation

/// 單次程序啟動的身分與時間；供診斷匯出從本次啟動開始篩選。
enum AppSession {
    static let launchDate = Date()
    static let launchID = UUID().uuidString

    static func markLaunch() {
        sendlog(message: "[AppSession] launch id=\(launchID) startedAt=\(launchDate.timeIntervalSince1970)")
    }
}
