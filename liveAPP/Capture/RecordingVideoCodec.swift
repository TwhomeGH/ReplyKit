#if os(iOS)
import Foundation

/// 本機錄影（SCRecordingOutput）的視訊編碼偏好。
/// 實際可用清單由 `SCRecordingOutputConfiguration.availableVideoCodecTypes` 於執行期決定，
/// 這裡只用字串比對辨識，避免引用較新 SDK 才提供的 case。
enum RecordingVideoCodec: String, CaseIterable, Identifiable {
    case auto
    case h264
    case hevc
    case av1

    var id: String { rawValue }

    /// 對應 `AVVideoCodecType` 的 rawValue；`auto` 由解析器決定。
    var codecIdentifier: String? {
        switch self {
        case .auto: return nil
        case .h264: return "avc1"
        case .hevc: return "hvc1"
        case .av1:  return "av01"
        }
    }

    var title: String {
        switch self {
        case .auto: return "自動（裝置最佳）"
        case .h264: return "H.264（AVC，最相容）"
        case .hevc: return "HEVC（H.265，較小）"
        case .av1:  return "AV1"
        }
    }

    static let storageKey = "recordingVideoCodec"

    /// 讀取使用者偏好；未設定時為 `.auto`。
    static var current: RecordingVideoCodec {
        RecordingVideoCodec(rawValue: userDefaults?.string(forKey: storageKey) ?? "") ?? .auto
    }
}
#endif
