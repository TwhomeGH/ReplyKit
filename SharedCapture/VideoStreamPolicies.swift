import Foundation

/// RTMP／VideoToolbox 輸入緩衝的可序列化策略。
///
/// 舊資料以 `-1` 表示自動，但 `0` 也被部分入口接受；統一後 `<= 0` 都是
/// `.automatic`，固定值上限 100。`maxFrameDelayCount` 使用 -1（VT 自動），
/// `setVideoInputBufferCounts` 則回傳 nil。
enum VideoBufferPolicy: Equatable, Sendable {
    case automatic
    case frames(Int)

    static let maximumFrames = 100

    static func resolve(rawValue: Int) -> VideoBufferPolicy {
        rawValue > 0 ? .frames(min(rawValue, maximumFrames)) : .automatic
    }

    var rawValue: Int {
        switch self {
        case .automatic: return -1
        case .frames(let count): return count
        }
    }

    var maxFrameDelayCount: Int {
        switch self {
        case .automatic: return -1
        case .frames(let count): return count
        }
    }

    var inputBufferCounts: Int? {
        switch self {
        case .automatic: return nil
        case .frames(let count): return count
        }
    }
}

/// Keyframe 間隔策略；0 代表 automatic，不能再 fallback 成固定 2 秒。
enum KeyFrameIntervalPolicy: Equatable, Sendable {
    case automatic
    case seconds(Int)

    static let maximumSeconds = 60

    static func resolve(rawValue: Int) -> KeyFrameIntervalPolicy {
        rawValue > 0 ? .seconds(min(rawValue, maximumSeconds)) : .automatic
    }

    /// HaishinKit 的設定值：0 表示不送 duration／frame interval option。
    var duration: Int32 {
        switch self {
        case .automatic: return 0
        case .seconds(let seconds): return Int32(seconds)
        }
    }

    var rawValue: Int {
        switch self {
        case .automatic: return 0
        case .seconds(let seconds): return seconds
        }
    }
}
