import Foundation

/// 兩種擷取來源共用的 AAC 推流碼率偏好。自動跟隨 RTMP 建議值，不切換 AAC 編碼種類。
enum StreamAudioBitrate: String, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case kbps128 = "128"
    case kbps96 = "96"
    case kbps64 = "64"

    static let storageKey = "streamAudioBitrate"
    var id: String { rawValue }
    var titleKey: String { "audio.bitrate." + rawValue }

    /// 舊版沒有偏好或儲存值無效時沿用自動，避免意外套用零碼率。
    static func load(from defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .automatic
    }

    /// 單位為 bit/s。建議值由呼叫端傳入，確保與實際使用的 HaishinKit 版本一致。
    func resolve(recommended: Int) -> Int {
        switch self {
        case .automatic: return recommended > 0 ? recommended : 128_000
        case .kbps128: return 128_000
        case .kbps96: return 96_000
        case .kbps64: return 64_000
        }
    }
}
