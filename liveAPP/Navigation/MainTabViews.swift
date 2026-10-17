import SwiftUI

/// 主頁保留擷取設定與狀態；聊天室操作集中在可返回的子頁。
struct HomeTabView: View {
  var body: some View {
    NavigationStack {
      homeView()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
            NavigationLink {
              PIPView()
                .navigationTitle(AppLanguage.localized("tab.chat"))
            } label: {
              Label(AppLanguage.localized("tab.chat"), systemImage: "pip.enter")
            }
          }
        }
    }
  }
}

/// 設備採樣與離線碼率分析共用導覽；推入分析頁時沿用設備頁的離開清理。
struct DeviceTabView: View {
  var body: some View {
    NavigationStack {
      DeviceView()
        .navigationTitle(AppLanguage.localized("tab.deviceInfo"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
            NavigationLink {
              VideoBitrateView()
                .navigationTitle(AppLanguage.localized("tab.bitrate"))
            } label: {
              Label(AppLanguage.localized("tab.bitrate"), systemImage: "chart.bar.xaxis")
            }
          }
        }
    }
  }
}

/// 音量與 TTS 共用音訊分頁；選擇由頂層持有，供即時音量訂閱判斷。
/// TTS 已有自己的導覽容器，這裡不再包一層 NavigationStack。
struct AudioTabView: View {
  @Binding var showsTTS: Bool

  var body: some View {
    VStack(spacing: 0) {
      Picker(AppLanguage.localized("settings.audio.title"), selection: $showsTTS) {
        Text(AppLanguage.localized("tab.volume")).tag(false)
        Text(AppLanguage.localized("tab.tts")).tag(true)
      }
      .pickerStyle(.segmented)
      .padding()

      if showsTTS {
        TTSSettingsView()
      } else {
        LiveVolumeView()
      }
    }
  }
}
