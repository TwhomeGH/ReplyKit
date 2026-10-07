import ReplayKit
import SwiftUI
import Combine
import os
import Foundation

/// 日誌來源篩選，rawValue 保留既有偏好相容性。
enum LogMode: Int, CaseIterable, Identifiable {
    case app = 1       // 對應 App
    case external = 0  // 對應 外部
    case both = 2

    var id: Int { self.rawValue }

    var description: String {
        switch self {
        case .app: return "App"
        case .external: return "外部"
        case .both: return "App + 外部"
        }
    }
}



// MARK: Log 顯示 UIViewRepresentable

/// 導覽使用的日誌入口，歷史讀取由 FileLogView 負責。
struct LogView: View {
    var body: some View { FileLogView() }
}
