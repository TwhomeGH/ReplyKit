import Combine
import Foundation
import ReplayKit
import SwiftUI
import os

/// 分頁與頂層生命週期入口；各功能狀態由原本擁有者管理。
struct ContentView: View {

  @Environment(\.scenePhase) private var scenePhase

  @EnvironmentObject var logModel: LogModel

  @StateObject private var pageState = PageState()

  @AppStorage("BacklogTime", store: userDefaults) private var logTime = false

  @AppStorage("onlogPage", store: userDefaults) private var onlogPage = false

  @AppStorage("onAudioPage", store: userDefaults) private var onAudioPage = false

  @State private var showsTTS = false

  var body: some View {

    TabView(selection: $pageState.currentPage) {

      HomeTabView()
        .tabItem { Label("tab.home", systemImage: "house") }
        .tag(AppPage.home)

      DeviceTabView()
        .tabItem { Label("tab.deviceInfo", systemImage: "cpu") }
        .tag(AppPage.testpage)

      LogView()
        .environmentObject(logModel)
        .tabItem { Label("tab.logs", systemImage: "apple.terminal") }
        .tag(AppPage.log)

      AudioTabView(showsTTS: $showsTTS)
        .environmentObject(pageState)
        .tabItem {
          Label(AppLanguage.localized("tab.audio"), systemImage: "speaker.wave.2")
        }
        .tag(AppPage.audio)

      NavigationStack { AppSettingsView() }
        .tabItem { Label(AppLanguage.localized("tab.tools"), systemImage: "square.grid.2x2") }
        .tag(AppPage.settings)

    }
    .onChange(of: pageState.currentPage) { newValue in
      sendlog(message: "Page:\(newValue)")

      if newValue == .log {
        pageState.onlogPage = true
        onlogPage = true
        LPConfig.shared.onLogPage = true
        CFNotificationCenterPostNotification(
          cfCenter, CFNotificationName("onlogPage" as CFString), nil, nil, true)
      } else if !logTime {
        pageState.onlogPage = false
        onlogPage = false
        LPConfig.shared.onLogPage = false
        CFNotificationCenterPostNotification(
          cfCenter, CFNotificationName("onlogPage" as CFString), nil, nil, true)
      }

      updateAudioSubscription()
    }
    .onChange(of: showsTTS) { _ in updateAudioSubscription() }
    .onAppear { updateAudioSubscription() }

    .onChange(of: scenePhase) {
      newPhase in

      switch newPhase {
      case .active:

        SocketServer.shared.ensureRunning()

        if pageState.onlogPage {
          if onlogPage == false {
            onlogPage = true

            CFNotificationCenterPostNotification(
              cfCenter, CFNotificationName("onlogPage" as CFString), nil, nil, true)

          }
        }

        sendlog(message: "正在App中！")

        updateAudioSubscription()

      case .background:

        if onlogPage == true {

          if logTime {

            sendlog(message: "應用已進入後台App 仍保持更新logPage")

          } else {

            sendlog(message: "應用已進入後台App 停止更新logPage")

            onlogPage = false

            CFNotificationCenterPostNotification(
              cfCenter, CFNotificationName("onlogPage" as CFString), nil, nil, true)

          }

        }

        updateAudioSubscription()

      case .inactive:
        updateAudioSubscription()

        sendlog(message: "正在離開App")

      @unknown default:
        sendlog(message: "後台未知狀態 不處理")
      }
    }

  }
  /// 只有前景音量頁需要即時資料；切到 TTS、其他分頁或背景即停止訂閱。
  /// 先比對保存狀態，避免每次視圖重算都向擴展重送相同命令。
  private func updateAudioSubscription() {
    let visible = pageState.currentPage == .audio && !showsTTS
    pageState.onAudioPage = visible
    let enabled = visible && scenePhase == .active
    guard onAudioPage != enabled else { return }
    onAudioPage = enabled
    sendlog(message: "onAudioPage: \(enabled)")
    SocketServer.shared.broadcastPushState(key: "onAudioPage", value: enabled)
  }

}
#Preview {
  ContentView()
}
