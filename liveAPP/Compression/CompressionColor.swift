import Foundation
import AVFoundation

/// 手動平均碼率壓縮的色彩策略；系統品質預設不套用此設定。
enum CompressionColorMode: String, CaseIterable, Sendable {
    case automatic, preserve, bt709

    var title: String {
        switch self {
        case .automatic: return "自動（保留已知資訊）"
        case .preserve: return "保留來源（嚴格）"
        case .bt709: return "SDR BT.709"
        }
    }
}

/// 從格式描述讀取的色彩標記；未知保持 nil，不依尺寸推測。
struct CompressionColorInfo: Sendable {
    let primaries: String?
    let transfer: String?
    let matrix: String?
    let fullRange: Bool?

    /// 只擷取純量，不持有格式描述或影片資源。
    init(extensions: [String: Any]) {
        primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
        fullRange = extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool
    }

    var complete: Bool { primaries != nil && transfer != nil && matrix != nil }
    var matrixLabel: String {
        guard let matrix else { return "未提供" }
        switch matrix {
        case "YCbCrMatrix#5", "YCbCrMatrix#6", AVVideoYCbCrMatrix_ITU_R_601_4: return "BT.601"
        case "YCbCrMatrix#1", AVVideoYCbCrMatrix_ITU_R_709_2: return "BT.709"
        case "YCbCrMatrix#9", AVVideoYCbCrMatrix_ITU_R_2020: return "BT.2020"
        default: return matrix
        }
    }
    var summary: String {
        "矩陣：\(matrixLabel)\n色域：\(primaries ?? "未提供")\n轉移函數：\(transfer ?? "未提供")\n範圍：\(fullRange.map { $0 ? "全範圍" : "有限範圍" } ?? "未提供")"
    }

    /// UI 與轉碼入口共用資格檢查；完整標記不代表編碼器一定接受。
    func restriction(for mode: CompressionColorMode) -> String? {
        if mode != .automatic && !complete { return "來源色域、轉移函數或矩陣未完整提供，無法可靠套用此策略。" }
        if mode != .automatic && fullRange == nil { return "來源範圍未提供，無法可靠保留或轉換。" }
        return nil
    }

    /// 預估必須標明未知，成品標記仍需重新讀取確認。
    func preview(for mode: CompressionColorMode) -> String {
        if let reason = restriction(for: mode) { return reason }
        switch mode {
        case .automatic:
            return "自動解析矩陣：\(matrixLabel)；色域：\(primaries ?? "由系統處理，待確認")；轉移函數：\(transfer ?? "由系統處理，待確認")。解碼使用有限範圍；成品標記待確認。"
        case .preserve: return "目標保留來源標記與範圍；成品驗證不符將報錯。\n" + summary
        case .bt709: return "目標矩陣／色域／轉移函數：BT.709；有限範圍。由 AVFoundation 依來源標記轉換，完成後檢查成品。"
        }
    }
}
