import Foundation
import Combine

/// 主頁碼率的單一來源；倍率只作畫面草稿，結束編輯才保存與通知擴展。
@MainActor final class BitrateManager: ObservableObject {
    static let base = 100_000
    @Published private(set) var multiplier: Int
    var bitrate: Int { multiplier * Self.base }

    init() {
        let saved: Int = getUserDefault(forKey: "bitRate") ?? 6_000_000
        multiplier = Self.normalizedMultiplier(savedBitrate: saved)
    }

    /// 無效負值／零使用 6 Mbps，其他值對齊 100 kbps 並限制於 1–20 Mbps。
    nonisolated static func normalizedMultiplier(savedBitrate: Int) -> Int {
        guard savedBitrate > 0 else { return 60 }
        return min(200, max(10, savedBitrate / 100_000))
    }

    /// 接收滑桿草稿，避免非有限值或越界值進入正式碼率。
    func setMultiplier(_ value: Double) {
        guard value.isFinite else { return }
        multiplier = Int(min(200, max(10, value)))
    }

    /// 使用者完成編輯才提交，初始化不改寫偏好設定。
    func updateStreamBitrate() {
        setUserDefault(bitrate, forKey: "bitRate")
        setUserDefault(multiplier, forKey: "bitRateMultiplier")
        CFNotificationCenterPostNotification(cfCenter, CFNotificationName("bitRateChange" as CFString), nil, nil, true)
        LPConfig.shared.streamBitrate = String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)
    }
}
