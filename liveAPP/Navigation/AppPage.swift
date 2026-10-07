import ReplayKit
import SwiftUI
import Combine
import os
import Foundation

/// 頂層分頁識別，供 TabView 與目前頁面狀態使用。
enum AppPage {
    case home
    case settings
    case profile
    case about
    case log
    case testpage
    case fps
    case audio
    case PIPChat
    case tts
    case videoBitrate

}

/// 由 ContentView 持有的分頁狀態，不建立擷取或 Socket 服務。
final class PageState: ObservableObject {
    @Published var currentPage: AppPage = .home
    @Published var onAudioPage: Bool = false
    @Published var onlogPage: Bool = false
}
