import SwiftUI
import UIKit

/// 切換安裝包內的圖示；以系統回報為準，不另外儲存可能失真的偏好值。
@MainActor
struct AppIconSettingsView: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var selectedName = UIApplication.shared.alternateIconName
  @State private var isChanging = false
  @State private var timeoutTask: Task<Void, Never>?
  @State private var errorMessage: String?
  @State private var diagnostics: AppIconDiagnostics?
  @State private var lastReport: String?

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
        Text(diagnostics?.explanation ?? AppLanguage.localized("appIcon.unsupported"))
          .foregroundStyle(.secondary)
      }
      if let diagnostics {
        Section {
          DisclosureGroup(AppLanguage.localized("appIcon.diagnostics")) {
            Text(diagnostics.report).font(.caption.monospaced()).textSelection(.enabled)
            Button(AppLanguage.localized("appIcon.copyDiagnostics")) {
              UIPasteboard.general.string = diagnostics.report
            }
          }
        }
      }
    }
    .navigationTitle(AppLanguage.localized("appIcon.title"))
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { refreshDiagnostics() }
    .onChange(of: scenePhase) { phase in
      if phase == .active { refreshDiagnostics() }
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

  /// 讀原始 plist 保留 ~ipad 分支；只在診斷改變時寫摘要，避免每次刷新重複記錄。
  private func refreshDiagnostics() {
    selectedName = UIApplication.shared.alternateIconName
    var info = Bundle.main.infoDictionary ?? [:]
    do {
      if let url = Bundle.main.url(forResource: "Info", withExtension: "plist") {
        let data = try Data(contentsOf: url)
        if let raw = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
          info = raw
        }
      }
    } catch {
      sendlog(title: "AppIcon", message: "讀取原始 plist 失敗，改用 Bundle 資訊：\((error as NSError).code)")
    }
    let snapshot = AppIconDiagnostics(info: info, isPad: UIDevice.current.userInterfaceIdiom == .pad,
      supported: UIApplication.shared.supportsAlternateIcons, current: selectedName)
    diagnostics = snapshot
    if lastReport != snapshot.report {
      sendlog(title: "AppIcon", message: snapshot.report.replacingOccurrences(of: "\n", with: " | "))
      lastReport = snapshot.report
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
    .disabled(isChanging || !UIApplication.shared.supportsAlternateIcons || (name != nil && selectedName == name))
  }

  /// 請求系統切換圖示，完成後重新讀取實際結果；失敗保留系統錯誤供查看。
  /// - Parameter name: 已宣告的替換圖示名稱；nil 表示恢復預設。
  private func changeIcon(to name: String?) {
    guard !isChanging, UIApplication.shared.supportsAlternateIcons else { return }
    timeoutTask?.cancel()
    isChanging = true
    let requested = name ?? "nil"
    sendlog(title: "AppIcon", message: "setAlternateIconName start name=\(requested) current=\(UIApplication.shared.alternateIconName ?? "nil") path=\(Bundle.main.bundlePath)")
    timeoutTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 8_000_000_000)
      guard !Task.isCancelled, isChanging else { return }
      isChanging = false
      timeoutTask = nil
      errorMessage = AppLanguage.localized("appIcon.timeout")
      sendlog(title: "AppIcon", message: "setAlternateIconName timeout name=\(requested)")
      refreshDiagnostics()
    }
    UIApplication.shared.setAlternateIconName(name) { error in
      let nsError = error.map { $0 as NSError }
      let details = nsError.map {
        "domain=\($0.domain) code=\($0.code) path=\(Bundle.main.bundlePath)"
      } ?? "none"
      Task { @MainActor in
        timeoutTask?.cancel()
        timeoutTask = nil
        let current = UIApplication.shared.alternateIconName ?? "nil"
        sendlog(title: "AppIcon", message: "setAlternateIconName completion name=\(requested) current=\(current) \(details)")
        let message: String?
        if let error {
          message = (error as NSError).code == -54
            ? AppLanguage.localized("appIcon.permissionDenied")
            : error.localizedDescription
        } else {
          message = nil
        }
        selectedName = UIApplication.shared.alternateIconName
        isChanging = false
        errorMessage = message
        refreshDiagnostics()
      }
    }
  }
}
