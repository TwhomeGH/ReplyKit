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

/// 音訊分頁唯一的導覽容器；切換列位於導覽內容內，避免與 iPad 頂部分頁重疊。
struct AudioTabView: View {
    @Binding var showsTTS: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(AppLanguage.localized("tab.audio"), selection: $showsTTS) {
                    Text(AppLanguage.localized("tab.volume")).tag(false)
                    Text(AppLanguage.localized("tab.tts")).tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 400)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if showsTTS {
                    TTSSettingsView()
                } else {
                    LiveVolumeView()
                }
            }
            .navigationTitle(AppLanguage.localized("tab.audio"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
