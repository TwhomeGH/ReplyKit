import SwiftUI

/// 本機偏好不依賴 App Group；非法或舊值回到五分鐘。
enum LiveActivitySettings {
    static let intervals = [60, 300, 600, 900]
    /// 未設定時預設關閉；只有明確開啟才允許建立活動。
    static var enabled: Bool { UserDefaults.standard.object(forKey: "liveActivityEnabled") as? Bool ?? false }
    static var interval: TimeInterval {
        TimeInterval(validatedInterval(UserDefaults.standard.integer(forKey: "liveActivityInterval")))
    }

    /// 將缺少或不支援的設定值正規化為預設五分鐘。
    static func validatedInterval(_ value: Int) -> Int {
        intervals.contains(value) ? value : 300
    }
}

/// 即時動態偏好入口；切換只影響鎖定畫面與動態島，不操作擷取管線。
struct LiveActivitySettingsView: View {
    @AppStorage("liveActivityEnabled") private var enabled = false
    @AppStorage("liveActivityInterval") private var interval = 300
    @ObservedObject private var manager = StreamActivityManager.shared

    var body: some View {
        Form {
            Section {
                Toggle(AppLanguage.localized("activity.enabled"), isOn: $enabled)
                Picker(AppLanguage.localized("activity.interval"), selection: $interval) {
                    ForEach(LiveActivitySettings.intervals, id: \.self) { seconds in
                        Text("\(seconds / 60) min").tag(seconds)
                    }
                }
                .disabled(!enabled)
                Label(AppLanguage.localized(manager.isActivityActive ? "activity.active" : "activity.inactive"),
                      systemImage: manager.isActivityActive ? "waveform.circle.fill" : "waveform.circle")
            } footer: {
                Text(AppLanguage.localized("activity.explanation"))
            }
        }
        .navigationTitle(AppLanguage.localized("activity.title"))
        .onAppear { interval = LiveActivitySettings.validatedInterval(interval) }
        .onChange(of: enabled) { _ in manager.applySettings() }
        .onChange(of: interval) { _ in manager.applySettings() }
    }
}
