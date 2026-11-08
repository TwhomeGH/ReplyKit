import ReplayKit
import SwiftUI
import Combine
import os
import Foundation

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

/// RMS 與增益共用振幅轉 dB；音量表固定 −60…0 dBFS，不沿用滑桿的 −140 dB 範圍。
enum AudioLevelPresentation {
    /// 線性振幅換算；零為負無限，無效數值不冒充靜音。
    static func decibels(_ amplitude: Double) -> Double? {
        guard amplitude.isFinite, amplitude >= 0 else { return nil }
        return amplitude == 0 ? -.infinity : 20 * log10(amplitude)
    }

    /// 顯示數值不截斷；只有長條在顯示上下限飽和。
    static func label(_ amplitude: Double, unit: String = "dBFS") -> String {
        guard let db = decibels(amplitude) else { return "未提供" }
        return db == -.infinity ? "−∞ \(unit)" : String(format: "%.1f %@", db, unit)
    }

    static func level(_ amplitude: Double) -> Double {
        guard let db = decibels(amplitude) else { return 0 }
        return min(1, max(0, (db + 60) / 60))
    }
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
    @AppStorage("micAddVolume", store: userDefaults) private var micAddVolume: Double = 1
    @AppStorage("captureBackend", store: userDefaults) private var selectedBackend = CaptureBackend.replayKit.rawValue

    /// 開播以實際來源優先，未開播以選定後端判斷，避免沿用上一場的標籤。
    private var supportsMicGain: Bool {
        if !model.stopped, !LPConfig.shared.StreamEnded { return model.source != "ScreenCaptureKit" }
        return selectedBackend != CaptureBackend.screenCaptureKit.rawValue
    }


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
                                ?? AudioLevelPresentation.label(Double(model.mixedVolume ?? 0))))
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
                                Text("App 額外增益已停用，固定 1 ×；舊設定保留但不再套用。")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("volume.micGain")
                                gainSlider($micAddVolume, notification: "micAdd")
                                    .disabled(!supportsMicGain)
                                if !supportsMicGain {
                                    Text("ScreenCaptureKit 尚未支援額外 Mic 增益；一般 Mic 音量仍可使用。")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        Text(model.replayApplicationStatus(channel: "micGain", desired: micAddVolume, now: context.date))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
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
                Text("輸出增益")
                Spacer()
                Text(value.wrappedValue == 0 ? "靜音" : AudioLevelPresentation.label(value.wrappedValue, unit: "dB"))
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
            Text("控制推流／可控錄製的混音，不改變其他 App 的揚聲器音量。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let status = model.measurement(notification == "appVolumeChanged" ? "app" : "mic", now: context.date)
                HStack {
                    Text(model.source == "ScreenCaptureKit" ? "來源 RMS（調整前）" : "擴展回報音量")
                    Spacer()
                    Text(status ?? AudioLevelPresentation.label(measured)).monospacedDigit()
                }
                if status == nil {
                    meter(measured, color: color)
                }
                if model.source != "ScreenCaptureKit" {
                    Text(model.replayApplicationStatus(channel: notification == "appVolumeChanged" ? "app" : "mic",
                                                       desired: value.wrappedValue, now: context.date))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.source == "ScreenCaptureKit" {
                    let key = notification == "appVolumeChanged" ? "app" : "mic"
                    if let gain = model.appliedGains[key], !model.stopped {
                        let matches = abs(Double(gain) - value.wrappedValue) < 0.000001
                        Text(matches ? "Mixer 設定已套用" : "等待套用新設定")
                            .font(.caption).foregroundStyle(.secondary)
                        if status == nil {
                            HStack {
                                Text("調整後 RMS（估算）")
                                Spacer()
                                Text(AudioLevelPresentation.label(measured * Double(gain))).monospacedDigit()
                            }
                            meter(measured * Double(gain), color: color)
                            Text("依來源 RMS × 已套用增益估算；不是分軌輸出實測，混音輸出請看上方實測值。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(model.stopped ? "已停止套用" : "尚無此音軌套用回報")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("volume.measurementNote").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 所有來源／估算表共用固定刻度，避免不同振幅看起來都接近滿格。
    private func meter(_ amplitude: Double, color: Color) -> some View {
        VStack(spacing: 4) {
            SafeProgressBar(value: AudioLevelPresentation.level(amplitude), color: color)
            HStack {
                Text("−60")
                Spacer()
                Text("−30")
                Spacer()
                Text("0 dBFS")
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// 增益沿用原有範圍與通知名稱，只在使用者結束拖曳後通知擷取端。
    private func gainSlider(_ value: Binding<Double>, notification: String) -> some View {
        VStack(alignment: .leading) {
            Text(String(format: "%.1f × · %@", value.wrappedValue, AudioLevelPresentation.label(value.wrappedValue, unit: "dB"))).monospacedDigit()
            Slider(value: value, in: 1...30, step: 0.1) { editing in
                if !editing { publish(notification, value: value.wrappedValue) }
            }
        }
    }

    /// 保存值已由 AppStorage 寫入，這裡沿用跨程序通知觸發即時套用。
    private func publish(_ name: String, value: Double) {
        AudioControlCoordinator.notify(name, value: value)
    }
}
