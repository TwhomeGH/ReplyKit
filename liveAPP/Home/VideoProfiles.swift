import Foundation

/// HEVC 設定選項，不代表實際編碼輸出診斷。
enum HEVCProfile: String, CaseIterable, Identifiable {
    case main = "Main"
    case main10 = "Main10"
    case main42210 = "Main42210"

    var id: String { self.rawValue }
}
