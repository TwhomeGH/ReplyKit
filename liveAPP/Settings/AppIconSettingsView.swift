import SwiftUI
import UIKit

/// 切換安裝包內的圖示；以系統回報為準，不另外儲存可能失真的偏好值。
@MainActor
struct AppIconSettingsView: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var selectedName = UIApplication.shared.alternateIconName
  @State private var isChanging = false
  @State private var errorMessage: String?

  var body: some View {
    Form {
      Section {
        iconButton(name: nil, title: "appIcon.default")
        iconButton(name: "PersonalIcon", title: "appIcon.personal")
      } footer: {
        Text(AppLanguage.localized("appIcon.hint"))
      }
      if isChanging {
        ProgressView(AppLanguage.localized("appIcon.changing"))
      }
      if !UIApplication.shared.supportsAlternateIcons {
        Text(AppLanguage.localized("appIcon.unsupported"))
          .foregroundStyle(.secondary)
      }
    }
    .navigationTitle(AppLanguage.localized("appIcon.title"))
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { selectedName = UIApplication.shared.alternateIconName }
    .onChange(of: scenePhase) { phase in
      if phase == .active { selectedName = UIApplication.shared.alternateIconName }
    }
    .alert(AppLanguage.localized("appIcon.failed"), isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button(AppLanguage.localized("appIcon.ok")) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  /// 每列保留目前選用標記；切換期間阻止重複請求。
  private func iconButton(name: String?, title: String) -> some View {
    Button {
      changeIcon(to: name)
    } label: {
      HStack {
        Image(name == nil ? "DefaultIconPreview" : "PersonalIconPreview")
          .resizable()
          .scaledToFit()
          .frame(width: 56, height: 56)
          .clipShape(RoundedRectangle(cornerRadius: 12))
        Text(AppLanguage.localized(title))
        Spacer()
        if selectedName == name {
          Image(systemName: "checkmark.circle.fill")
            .accessibilityLabel(AppLanguage.localized("appIcon.selected"))
        }
      }
    }
    .disabled(isChanging || !UIApplication.shared.supportsAlternateIcons || selectedName == name)
  }

  /// 請求系統切換圖示，完成後重新讀取實際結果；失敗保留系統錯誤供查看。
  /// - Parameter name: 已宣告的替換圖示名稱；nil 表示恢復預設。
  private func changeIcon(to name: String?) {
    guard !isChanging, UIApplication.shared.supportsAlternateIcons else { return }
    isChanging = true
    UIApplication.shared.setAlternateIconName(name) { error in
      let message = error?.localizedDescription
      Task { @MainActor in
        selectedName = UIApplication.shared.alternateIconName
        isChanging = false
        errorMessage = message
      }
    }
  }
}
