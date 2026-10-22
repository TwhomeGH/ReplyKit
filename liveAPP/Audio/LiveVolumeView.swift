import ReplayKit
import SwiftUI
import Combine
import os
import Foundation

@MainActor
final class LiveVolumeModel: ObservableObject {
    static let shared = LiveVolumeModel()   // 全局共用單例

    @Published var micVolumeLive: Float = 0.0
    @Published var appVolumeLive: Float = 0.0

    /// 本機擷取優先持有回報權；nil 表示接受舊版 ReplayKit 傳輸。
    private var captureSession: String?
    @Published private(set) var source = "ReplayKit"
    @Published private(set) var mixedVolume: Float?
    @Published private(set) var sampledAt: [String: Date] = [:]
    @Published private(set) var stopped = false
    private var visibleViews: Set<UUID> = []
    var monitoringVisible: Bool { !visibleViews.isEmpty }

    /// 多視窗各自登記，避免其中一個關閉便停用其他視窗的監測。
    func setVisible(_ visible: Bool, id: UUID) {
        if visible { visibleViews.insert(id) } else { visibleViews.remove(id) }
    }

    /// 開始本機 session，清除上一來源的值與時間。
    func beginCapture(_ session: String) {
        captureSession = session
        source = "ScreenCaptureKit"
        stopped = false
        sampledAt = [:]
        mixedVolume = nil
        micVolumeLive = 0
        appVolumeLive = 0
    }

    /// 停止後保留來源標籤，但所有數值都不可再視為即時資料。
    func endCapture(_ session: String) {
        guard captureSession == session else { return }
        captureSession = nil
        stopped = true
        sampledAt = [:]
        mixedVolume = nil
    }

    /// RMS 為線性振幅；來源分軌在 Mixer 音量調整前，mixed 在混音後。
    /// nil 表示讀取失敗／格式不支援；不得轉成有效靜音。
    func reportCapture(_ session: String, channel: String, rms: Float?, at: Date) {
        guard captureSession == session else { return }
        guard let rms, rms.isFinite, rms >= 0 else {
            sampledAt[channel] = nil
            return
        }
        sampledAt[channel] = at
        switch channel {
        case "app": appVolumeLive = rms
        case "mic": micVolumeLive = rms
        default: mixedVolume = rms
        }
    }

    /// 回報缺席與有效零值分開；過期判斷只在頁面重繪時計算。
    func measurement(_ channel: String, now: Date) -> String? {
        if stopped { return "已停止" }
        guard let at = sampledAt[channel] else { return "未收到資料" }
        return now.timeIntervalSince(at) > 3 ? "資料已過期" : nil
    }

    init(observeNotifications: Bool = true) {
        guard observeNotifications else { return }
#if os(iOS)

        if !LPConfig.shared.SocketLog && !LPConfig.isSideload {
        CFNotificationCenterAddObserver(cfCenter,
                                        UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                                        { _, observer, name, _,_  in
            guard let observer = observer else { return }
            let model = Unmanaged<LiveVolumeModel>.fromOpaque(observer).takeUnretainedValue()

            Task { @MainActor in
                model.updateVolumes(mic: getUserDefault(forKey: "micVolumeLive"), app: getUserDefault(forKey: "appVolumeLive"))
            }
        },
                                        "LiveVolumeUpdated" as CFString,
                                        nil,
                                        .deliverImmediately)

        }

#else

        if !LPConfig.shared.SocketLog && !LPConfig.isSideload {
            NotificationCenter.default.addObserver(
                forName: Notification.Name("LiveVolumeUpdated"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    self.updateVolumes(mic: getUserDefault(forKey: "micVolumeLive"), app: getUserDefault(forKey: "appVolumeLive"))
                }
            }

        }
#endif
    }

    deinit {
#if os(iOS)
        CFNotificationCenterRemoveEveryObserver(cfCenter,
            UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()))
#else
        NotificationCenter.default.removeObserver(self)
#endif
    }

    /// ReplayKit 相容入口；本機擷取期間拒收擴展值，不再將接收事件重新廣播造成回授。
    func updateVolumes(mic: Float? = nil, app: Float? = nil, persist: Bool = false) {
        guard captureSession == nil else { return }
        source = "ReplayKit"
        stopped = LPConfig.shared.StreamEnded
        if let mic = mic, mic.isFinite, mic >= 0 {
            sampledAt["mic"] = Date()
            self.micVolumeLive = mic
            if persist {
            setUserDefault(mic, forKey: "micVolumeLive")
            }
        }
        if let app = app, app.isFinite, app >= 0 {
            sampledAt["app"] = Date()
            self.appVolumeLive = app
            if persist {
            setUserDefault(app, forKey: "appVolumeLive")
            }
        }


    }
}



let minimumAudibleVolume: Double = 0.0000001
let volumeSliderStep: Double = 0.0000001

private func clampUnit(_ value: Double) -> Double {
    min(max(value, 0), 1)
}

private func formatPreciseVolumePercent(_ volume: Double) -> String {
    let percent = clampUnit(volume) * 100
    switch percent {
    case 0:
        return "0%"
    case ..<0.00001:
        return String(format: "%.8f%%", percent)
    case ..<0.01:
        return String(format: "%.5f%%", percent)
    case ..<1:
        return String(format: "%.3f%%", percent)
    default:
        return String(format: "%.2f%%", percent)
    }
}

private func formatSliderPercent(_ percentage: Double) -> String {
    String(format: "%.5f%%", clampUnit(percentage) * 100)
}

private func visualVolumeLevel(_ volume: Double) -> Double {
    guard volume > 0 else { return 0 }
    return volumeToPercentage(volume)
}

// MARK: UI 百分比 (0~1) → 真實音量 (0~1)，用 dB 對數曲線控制低音量精度
func percentageToVolume(_ percentage: Double) -> Double {
    let clamped = clampUnit(percentage)
    guard clamped > 0 else { return 0 }

    let minimumDecibels = 20 * log10(minimumAudibleVolume)
    let decibels = minimumDecibels + (0 - minimumDecibels) * clamped
    return pow(10, decibels / 20)
}

/// 真實音量 (0~1) → UI 百分比 (0~1)
func volumeToPercentage(_ volume: Double) -> Double {
    let clamped = clampUnit(volume)
    guard clamped > 0 else { return 0 }
    guard clamped < 1 else { return 1 }

    let minimumDecibels = 20 * log10(minimumAudibleVolume)
    let decibels = max(20 * log10(clamped), minimumDecibels)
    return clampUnit((decibels - minimumDecibels) / -minimumDecibels)
}

// 自繪進度條 (取代 ProgressView)
struct SafeProgressBar: View {
    var value: Double      // 0.0 ~ 1.0
    var color: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(Color.gray.opacity(0.18))
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(0.45),
                                color
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(height, geometry.size.width * CGFloat(clampUnit(value))))
                    .opacity(value > 0 ? 1 : 0)
                HStack(spacing: 0) {
                    ForEach(1..<4) { _ in
                        Spacer()
                        Rectangle()
                            .fill(Color.primary.opacity(0.16))
                            .frame(width: 1)
                    }
                }
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.2), value: value)
    }
}

/// 音量頁及即時音量顯示，沿用共享模型與原本監聽生命週期。
/// 音量控制與實測分開呈現；沿用既有非線性滑桿換算與設定通知。
struct LiveVolumeView: View {
    @StateObject private var model = LiveVolumeModel.shared
    @State private var visibilityID = UUID()
    @EnvironmentObject private var pageState: PageState
    @AppStorage("appVolume", store: userDefaults) private var appVolume: Double = 1
    @AppStorage("micVolume", store: userDefaults) private var micVolume: Double = 1
    @AppStorage("appAddVolume", store: userDefaults) private var appAddVolume: Double = 1
    @AppStorage("micAddVolume", store: userDefaults) private var micAddVolume: Double = 1

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(AppLanguage.localized(pageState.onAudioPage ? "volume.monitorOn" : "volume.monitorOff"),
                          systemImage: "waveform")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(model.source == "ScreenCaptureKit" ? "ScreenCaptureKit · App／Mic 為混音前 RMS" : "ReplayKit · 擴展回報音量")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.source == "ScreenCaptureKit" {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("混音輸出 RMS：" + (model.measurement("mixed", now: context.date)
                                ?? formatPreciseVolumePercent(Double(model.mixedVolume ?? 0))))
                                .font(.caption).monospacedDigit()
                        }
                    }
                    AdaptiveSettingsColumns(width: geometry.size.width) {
                        channel(title: "volume.app", value: $appVolume,
                                measured: Double(model.appVolumeLive), color: .blue,
                                notification: "appVolumeChanged")
                    } trailing: {
                        channel(title: "volume.mic", value: $micVolume,
                                measured: Double(model.micVolumeLive), color: .red,
                                notification: "micVolumeChanged")
                    }
                    SettingsDashboardCard("volume.advanced") {
                        DisclosureGroup("volume.gainAndRaw") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("volume.legacyAppGain")
                                gainSlider($appAddVolume, notification: "appAdd")
                                Text("volume.micGain")
                                gainSlider($micAddVolume, notification: "micAdd")
                                Text("App: \(formatPreciseVolumePercent(appVolume)) · Mic: \(formatPreciseVolumePercent(micVolume))")
                                    .font(.caption).textSelection(.enabled)
                            }.padding(.top, 8)
                        }
                    }
                }
                .frame(maxWidth: 1280)
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(16)
            }
        }
        .onAppear { model.setVisible(true, id: visibilityID) }
        .onDisappear { model.setVisible(false, id: visibilityID) }
    }

    /// 滑桿百分比是控制刻度；實測值另外標示，不把設定值當作訊號音量。
    private func channel(title: LocalizedStringKey, value: Binding<Double>, measured: Double,
                         color: Color, notification: String) -> some View {
        SettingsDashboardCard(title) {
            HStack {
                Text("volume.setting")
                Spacer()
                Text(String(format: "%.1f%%", volumeToPercentage(value.wrappedValue) * 100))
                    .monospacedDigit()
            }
            Slider(value: Binding(
                get: { volumeToPercentage(value.wrappedValue) },
                set: { percent in
                    if abs(percent - 1) < volumeSliderStep { value.wrappedValue = 1 }
                    else if abs(percent) < volumeSliderStep { value.wrappedValue = 0 }
                    else { value.wrappedValue = percentageToVolume(percent) }
                }), in: 0...1, step: volumeSliderStep,
                onEditingChanged: { editing in
                    if !editing { publish(notification, value: value.wrappedValue) }
                })
                .tint(color)
            HStack { Text("0%"); Spacer(); Text("50%"); Spacer(); Text("100%") }
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let status = model.measurement(notification == "appVolumeChanged" ? "app" : "mic", now: context.date)
                HStack {
                    Text("volume.measured")
                    Spacer()
                    Text(status ?? formatPreciseVolumePercent(measured)).monospacedDigit()
                }
                if status == nil { SafeProgressBar(value: visualVolumeLevel(measured), color: color) }
            }
            Text("volume.measurementNote").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 增益沿用原有範圍與通知名稱，只在使用者結束拖曳後通知擷取端。
    private func gainSlider(_ value: Binding<Double>, notification: String) -> some View {
        VStack(alignment: .leading) {
            Text(String(format: "%.1f ×", value.wrappedValue)).monospacedDigit()
            Slider(value: value, in: 1...30, step: 0.1) { editing in
                if !editing { publish(notification, value: value.wrappedValue) }
            }
        }
    }

    /// 保存值已由 AppStorage 寫入，這裡沿用跨程序通知觸發即時套用。
    private func publish(_ name: String, value: Double) {
        #if os(iOS)
        CFNotificationCenterPostNotification(cfCenter, CFNotificationName(name as CFString), nil, nil, true)
        #else
        NotificationCenter.default.post(name: Notification.Name(name), object: nil)
        #endif
        sendlog(message: "[AudioControl] \(name) value=\(value)")
    }
}
