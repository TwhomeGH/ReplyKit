/// 廣播擴展識別與維護入口；只顯示設定，不在開頁時執行維護操作。
import Foundation

import SwiftUI

struct AdvancedSettingsView: View {
  @AppStorage("broadcastExtension", store: userDefaults) private var broadcastExtension =
    (Bundle.main.bundleIdentifier ?? "nuclear.liveAPP") + ".ReplyKIT"
  var body: some View {
    Form {
      Section(header: Text("settings.broadcastExtension.section")) {
        TextField(
          (Bundle.main.bundleIdentifier ?? "nuclear.liveAPP") + ".ReplyKIT",
          text: $broadcastExtension
        )
        .autocapitalization(.none)
        .disableAutocorrection(true)
        .font(.caption)
        Text("settings.broadcastExtension.restartNote")
          .font(.footnote)
          .foregroundColor(.secondary)
      }
      NavigationLink(AppLanguage.localized("settings.category.maintenance")) {
        MaintenanceSettingsView()
      }
    }
    .navigationTitle(AppLanguage.localized("settings.category.advanced"))

  }
}
