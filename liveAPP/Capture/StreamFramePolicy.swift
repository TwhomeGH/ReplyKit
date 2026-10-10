#if os(iOS)
import CoreGraphics
import Foundation

/// 推流輸出「畫布」政策：決定 RTMP 串流宣告的畫布比例，以及來源畫面如何填進畫布。
///
/// 語意刻意分成兩件事：
/// - **畫布比例**：`standard*` 固定 16:9；`native` 跟隨來源比例。
/// - **填入方式**：`.standard` 等比內縮、多餘處補黑邊（不裁切）；`.standardFill`
///   等比放大到填滿、超出的部分裁掉（無黑邊）。`native` 兩者皆無。
///
/// 預設為 `.standard`（安全：不裁切內容、輸出尺寸固定、對播放器/平台最一致）。
enum StreamFramePolicy: String, CaseIterable, Identifiable {
    /// 16:9 畫布，來源等比內縮置中，四周補黑邊。
    case standard
    /// 16:9 畫布，來源等比放大填滿，超出的部分裁切。
    case standardFill
    /// 跟隨來源比例，畫布即來源尺寸（不補黑邊、不裁切）。
    case native

    static let storageKey = "streamFramePolicy"

    /// 16:9 畫布的固定尺寸（`standard*` 用）。
    static let standardCanvas = CGSize(width: 1920, height: 1080)

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "16:9（含黑邊）"
        case .standardFill: return "16:9（裁切填滿）"
        case .native: return "跟隨來源比例"
        }
    }

    var detail: String {
        switch self {
        case .standard: return "固定 1920×1080，來源等比縮放後置中，不足處補黑邊"
        case .standardFill: return "固定 1920×1080，來源放大到填滿，超出部分裁切"
        case .native: return "輸出尺寸 = 擷取來源比例（4:3、直向等維持原樣）"
        }
    }

    /// 是否把來源填進固定 16:9 畫布。
    var usesFixedCanvas: Bool { self != .native }

    /// 固定畫布尺寸；`native` 回傳 nil（代表沿用來源尺寸）。
    var fixedCanvas: CGSize? { usesFixedCanvas ? Self.standardCanvas : nil }

    /// 來源填入畫布的方式：true = 裁切填滿，false = 內縮含黑邊。
    var fillsCanvas: Bool { self == .standardFill }

    static var current: StreamFramePolicy {
        StreamFramePolicy(rawValue: userDefaults?.string(forKey: storageKey) ?? "") ?? .standard
    }
}
#endif
