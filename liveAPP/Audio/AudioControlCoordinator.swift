import Foundation

/// 主 App 音訊控制通知入口；設定由畫面綁定保存，通知只觸發擷取端重新讀取快照。
/// ReplayKit 負責跨程序確認；ScreenCaptureKit 由同程序工作讀取同一設定模型。
enum AudioControlCoordinator {
    static func notify(_ name: String, value: Double) {
        guard ["appVolumeChanged", "micVolumeChanged", "micAdd"].contains(name) else { return }
        #if os(iOS)
        CFNotificationCenterPostNotification(cfCenter, CFNotificationName(name as CFString), nil, nil, true)
        #else
        NotificationCenter.default.post(name: Notification.Name(name), object: nil)
        #endif
        sendlog(message: "[AudioControl] \(name) value=\(value)")
    }
}
