import Foundation
import VideoToolbox

/// 主 App 與廣播擴展共用的 H.264 設定解析；不依解析度猜測 Level。
enum H264EncodingProfile {
    /// 舊版名稱轉為 AutoLevel；已保存的系統 ProfileLevel 原值保留。
    /// 未知舊值沿用原本 Main AutoLevel 後備，不寫回使用者偏好。
    static func resolve(_ value: String) -> String {
        switch value {
        case "Baseline", "AutoBaseline": return kVTProfileLevel_H264_Baseline_AutoLevel as String
        case "Main", "AutoMain": return kVTProfileLevel_H264_Main_AutoLevel as String
        case "High", "AutoHigh": return kVTProfileLevel_H264_High_AutoLevel as String
        case "ConstrainedBaseline": return kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel as String
        case "ConstrainedHigh": return kVTProfileLevel_H264_ConstrainedHigh_AutoLevel as String
        case "Extended": return kVTProfileLevel_H264_Extended_AutoLevel as String
        default:
            return value.hasPrefix("H264_") ? value : kVTProfileLevel_H264_Main_AutoLevel as String
        }
    }

    /// 僅整理系統回傳的 H.264 值；不補入未經查詢的常數。
    static func supportedValues(_ values: [String]) -> [String] {
        Array(Set(values.filter { $0.hasPrefix("H264_") })).sorted()
    }

    /// 顯示系統值的可讀名稱，保留 Profile 與 Level 資訊。
    static func title(_ value: String) -> String {
        value.replacingOccurrences(of: "H264_", with: "")
            .replacingOccurrences(of: "_AutoLevel", with: " · AutoLevel")
            .replacingOccurrences(of: "_", with: ".")
    }
}
