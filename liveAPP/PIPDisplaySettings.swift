import SwiftUI

/// 一般 PiP 偏好；保活模式維持自己的更新間隔。
enum PIPDisplaySettings {
    static var clockSeconds: Double { validatedClock(userDefaults?.double(forKey: "pipClockSeconds") ?? 1) }
    static var powerSaving: Bool { userDefaults?.bool(forKey: "pipPowerSaving") ?? false }
    static var secondaryMode: String {
        let value = userDefaults?.string(forKey: "pipSecondaryMode") ?? "summary"
        return ["normal", "summary", "hidden"].contains(value) ? value : "summary"
    }

    /// 無效值回復一秒，避免零間隔與不可預期的刷新頻率。
    static func validatedClock(_ value: Double) -> Double { [1.0, 2.0, 5.0].contains(value) ? value : 1 }
}

/// 聊天室刷新與訊息偏好；修改時不主動建立 PiP 服務。
struct PIPDisplaySettingsSection: View {
    @AppStorage("pipClockSeconds", store: userDefaults) private var seconds = 1.0
    @AppStorage("pipPowerSaving", store: userDefaults) private var saving = false
    @AppStorage("pipSecondaryMode", store: userDefaults) private var secondary = "summary"

    var body: some View {
        Section("聊天室 PiP") {
            Picker("時間刷新", selection: $seconds) {
                Text("每秒").tag(1.0)
                Text("每 2 秒").tag(2.0)
                Text("每 5 秒").tag(5.0)
            }
            Toggle("降低聊天室動畫頻率", isOn: $saving)
            Picker("次要訊息", selection: $secondary) {
                Text("一般顯示").tag("normal")
                Text("單行提示").tag("summary")
                Text("隱藏").tag("hidden")
            }
            Text("新訊息會提早更新。自動模式活動／動畫為 6／16 FPS，開啟後降為 3／8 FPS，捲動較不流暢；不影響直播影片 FPS。單行提示只保留最新次要訊息，約 5 秒後消失，不占主要聊天佇列；設定不影響 TTS。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { seconds = PIPDisplaySettings.validatedClock(seconds) }
        .onChange(of: seconds) { _ in apply() }
        .onChange(of: saving) { _ in apply() }
        .onChange(of: secondary) { _ in apply() }
    }

    /// 重排已存在的渲染排程；沒有啟動 PiP 時只保存偏好。
    private func apply() { PIPService.diagnosticInstance?.applyDisplaySettings() }
}
