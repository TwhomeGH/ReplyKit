/// 一般偏好設定，目前提供 App 語言選擇。
import Foundation

import SwiftUI

struct GeneralSettingsView: View {
  @AppStorage("AppLanguage", store: userDefaults) private var appLanguageRawValue = AppLanguage
    .system.rawValue
  var body: some View {
    Form {
      Section(header: Text("appLanguage.section")) {
        Picker("appLanguage.picker", selection: $appLanguageRawValue) {
          ForEach(AppLanguage.allCases) { language in
            Text(LocalizedStringKey(language.titleKey)).tag(language.rawValue)
          }
        }
        Text("appLanguage.restartHint")
          .font(.footnote)
          .foregroundColor(.secondary)
      }
    }
    .navigationTitle(AppLanguage.localized("settings.category.general"))

  }
}
