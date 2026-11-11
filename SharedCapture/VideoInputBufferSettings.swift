import Foundation

/// 編碼前原始影格佇列的可調上限；與 RTMP 網路待送 bytes、VT pending 不同。
///
/// ScreenCaptureKit 在主 App 行程內，可承受較大的預算；ReplayKit 擴展只有
/// 約 50 MB 空間，因此兩者使用不同預設與上限。
struct VideoInputBufferSettings: Equatable, Sendable {
    enum Source: Equatable {
        case screenCaptureKit
        case replayKit
    }

    static let screenCaptureKitBudgetKey = "screenCaptureKitVideoBufferMB"
    static let screenCaptureKitDurationKey = "screenCaptureKitVideoBufferDurationMS"
    static let replayKitBudgetKey = "replayKitVideoBufferMB"
    static let replayKitDurationKey = "replayKitVideoBufferDurationMS"

    static let screenCaptureKitDefaultMB = 32
    static let screenCaptureKitDefaultDurationMS = 150
    static let replayKitDefaultMB = 15
    static let replayKitDefaultDurationMS = 100

    let budgetMB: Int
    let durationMS: Int

    var budgetBytes: Int { budgetMB * 1024 * 1024 }
    var duration: TimeInterval { Double(durationMS) / 1000 }

    /// 讀取已保存值並限制在安全範圍；缺少設定時使用來源專屬預設。
    static func load(from defaults: UserDefaults?, source: Source) -> Self {
        let keys: (budget: String, duration: String, defaultMB: Int, defaultMS: Int)
        switch source {
        case .screenCaptureKit:
            keys = (screenCaptureKitBudgetKey, screenCaptureKitDurationKey,
                    screenCaptureKitDefaultMB, screenCaptureKitDefaultDurationMS)
        case .replayKit:
            keys = (replayKitBudgetKey, replayKitDurationKey,
                    replayKitDefaultMB, replayKitDefaultDurationMS)
        }
        let storedMB = defaults?.object(forKey: keys.budget) as? Int ?? keys.defaultMB
        let storedMS = defaults?.object(forKey: keys.duration) as? Int ?? keys.defaultMS
        // ReplayKit 擴展保留較低上限；不要把主 App 的 64 MB 設定帶進擴展。
        let maximumMB = source == .screenCaptureKit ? 64 : 24
        return Self(budgetMB: min(max(storedMB, 8), maximumMB),
                    durationMS: min(max(storedMS, 50), 500))
    }
}
