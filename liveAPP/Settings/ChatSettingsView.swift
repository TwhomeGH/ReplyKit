/// 聊天通知與 PiP 外觀入口；子頁共用既有設定來源。
import Foundation

import SwiftUI

struct ChatSettingsView: View {
  @AppStorage("isNotifyChat", store: userDefaults) private var isNotifyChat = false
  var body: some View {
    Form {
      Toggle(isOn: $isNotifyChat) {
        Text("啟用聊天訊息通知！")
      }

      Text("作為PIP子母窗口應高運存占用的替代方案，啟用後會對聊天訊息使用系統通知處理，避免PIP停止時訊息無法顯示的問題")
        .font(.footnote)
        .foregroundColor(.secondary)
        .padding(.bottom, 5)

      NavigationLink(AppLanguage.localized("settings.pipLog.title")) { PIPSettingsView() }
      NavigationLink(AppLanguage.localized("settings.pipLayout.title")) { PIPLayoutSettingsView() }
      NavigationLink(AppLanguage.localized("settings.pipLegacy.section")) {
        LegacyPIPSettingsView()
      }
    }
    .navigationTitle(AppLanguage.localized("settings.category.pip"))

  }
}
