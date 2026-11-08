import Foundation

/// 兩種擷取路徑共用的音訊控制快照。音量為線性振幅，Mic 額外增益為倍率。
/// App 額外增益已退場，不再進入設定快照；舊偏好保留供追溯。
struct AudioControlSettings: Codable, Equatable, Sendable {
    let schema: Int
    let app: Float
    let mic: Float
    let micGain: Float

    /// 讀取偏好並統一合法範圍；零音量保留為靜音，無效數值才回退原音量。
    init(defaults: UserDefaults) {
        schema = 2
        app = Self.validated(defaults.object(forKey: "appVolume") as? Double, range: 0...1)
        mic = Self.validated(defaults.object(forKey: "micVolume") as? Double, range: 0...1)
        micGain = Self.validated(defaults.object(forKey: "micAddVolume") as? Double, range: 1...30)
    }

    /// 解碼後仍須檢查版本與數值，避免外部資料繞過偏好正規化。
    var isValid: Bool {
        schema == 2 && app.isFinite && mic.isFinite && micGain.isFinite &&
        (0...1).contains(app) && (0...1).contains(mic) && (1...30).contains(micGain)
    }

    private static func validated(_ value: Double?, range: ClosedRange<Double>) -> Float {
        guard let value, value.isFinite else { return 1 }
        return Float(min(range.upperBound, max(range.lowerBound, value)))
    }
}
