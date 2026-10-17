/// 全域設定的唯一分類入口；子頁共用原有偏好，不建立新的擷取或連線服務。
import SwiftUI

struct AppSettingsView: View {
  @ObservedObject private var gpuSettings = GPUSettingsViewModel.shared

  var body: some View {
    List {
      Section {
        NavigationLink {
          GeneralSettingsView()
        } label: {
          row("settings.category.general", "globe")
        }
        NavigationLink {
          SocketConnectionSettingsView()
        } label: {
          row("settings.category.connection", "network")
        }
        NavigationLink {
          AudioSettingsView()
        } label: {
          row("settings.audio.title", "speaker.wave.2")
        }
      }
      Section(AppLanguage.localized("settings.category.appearance")) {
        NavigationLink(AppLanguage.localized("settings.outputOverlay.title")) {
          OverlaySettingsView()
        }
        NavigationLink(AppLanguage.localized("settings.gpu.title")) {
          GPURotateView(viewModel: gpuSettings)
        }
        NavigationLink(AppLanguage.localized("settings.category.encoding")) {
          LegacyEncodingSettingsView()
        }
        NavigationLink {
          ChatSettingsView()
        } label: {
          row("settings.category.pip", "pip")
        }
      }
      Section {
        NavigationLink {
          LogSettingsView()
        } label: {
          row("settings.category.logs", "doc.text")
        }
        NavigationLink {
          AdvancedSettingsView()
        } label: {
          row("settings.category.advanced", "slider.horizontal.3")
        }
        NavigationLink {
          AboutBuildView()
        } label: {
          row("settings.category.about", "info.circle")
        }
      }
    }
    .navigationTitle(AppLanguage.localized("tab.settings"))
    .navigationBarTitleDisplayMode(.inline)
  }

  /// 分類標籤沿用 App 內語言選擇，不依賴系統語言。
  private func row(_ key: String, _ symbol: String) -> some View {
    Label(AppLanguage.localized(key), systemImage: symbol)
  }
}
