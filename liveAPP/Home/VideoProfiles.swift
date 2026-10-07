import ReplayKit
import SwiftUI
import Combine
import os
import Foundation

/// H.264 設定選項，rawValue 對應既有保存值。
enum H264Profile: String, CaseIterable, Identifiable {
    case baseline = "Baseline"
    case main = "Main"
    case high = "High"
    case AutoBaseline = "AutoBaseline"
    case AutoMain = "AutoMain"
    case AutoHigh = "AutoHigh"

    case constrainedBaseline = "ConstrainedBaseline"
    case constrainedHigh = "ConstrainedHigh"
    case extended = "Extended"


    var id: String { self.rawValue }
}

/// HEVC 設定選項，不代表實際編碼輸出診斷。
enum HEVCProfile: String, CaseIterable, Identifiable {
    case main = "Main"
    case main10 = "Main10"
    case main42210 = "Main42210"

    var id: String { self.rawValue }
}
