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

    private init() {
#if os(iOS)

        if !LPConfig.shared.SocketLog && !LPConfig.isSideload {
        CFNotificationCenterAddObserver(cfCenter,
                                        UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                                        { _, observer, name, _,_  in
            guard let observer = observer else { return }
            let model = Unmanaged<LiveVolumeModel>.fromOpaque(observer).takeUnretainedValue()

            Task { @MainActor in
                model.micVolumeLive  = getUserDefault(forKey: "micVolumeLive") ?? 0.0
                model.appVolumeLive  = getUserDefault(forKey: "appVolumeLive") ?? 0.0
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
                    self.micVolumeLive = getUserDefault(forKey: "micVolumeLive") ?? 0.0
                    self.appVolumeLive = getUserDefault(forKey: "appVolumeLive") ?? 0.0
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

    // 🔹 新增一個全局更新函數
    func updateVolumes(mic: Float? = nil, app: Float? = nil, persist: Bool = false) {
        if let mic = mic {
            self.micVolumeLive = mic
            if persist {
            setUserDefault(mic, forKey: "micVolumeLive")
            }
        }
        if let app = app {
            self.appVolumeLive = app
            if persist {
            setUserDefault(app, forKey: "appVolumeLive")
            }
        }

        // 發送通知，讓其他地方也能收到更新
#if os(iOS)
        CFNotificationCenterPostNotification(cfCenter,
                                             CFNotificationName("LiveVolumeUpdated" as CFString),
                                             nil,
                                             nil,
                                             true)
#else
        NotificationCenter.default.post(name: Notification.Name("LiveVolumeUpdated"), object: nil)
#endif
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
struct LiveVolumeView: View {


    @StateObject var model = LiveVolumeModel.shared
    @EnvironmentObject var pageState: PageState

    @AppStorage("appVolume",store: userDefaults)  var appVolume: Double = 1.0
    @AppStorage("micVolume",store: userDefaults)  var micVolume: Double = 1.0

    @AppStorage("appAddVolume",store: userDefaults)  var appAddVolume: Double = 1.0
    @AppStorage("micAddVolume",store: userDefaults)  var micAddVolume: Double = 1.0



    init(){

    }

    var body: some View {


        VStack {
            HStack {
                Circle()
                    .fill(pageState.onAudioPage ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text("onAudioPage: \(pageState.onAudioPage ? "true" : "false")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            VStack {
                Text("[棄用]App增益: \(String(format: "%.1f", appAddVolume)) 倍")
                    .font(.headline)


                Slider(value: $appAddVolume, in: 1...30, step: 0.1,
                    onEditingChanged: {
                    editing in

                    if !editing {


#if os(iOS)

                        CFNotificationCenterPostNotification(
                            cfCenter,
                            CFNotificationName("appAdd" as CFString),
                            nil,
                            nil,
                            true
                        )
#else
                        NotificationCenter.default
                            .post(
                                name: Notification.Name("appAdd"),
                                object: nil
                            )
#endif

                        sendlog(message: String(
                            format: "應用增益更新: %.1f 倍",
                            appAddVolume
                        ))

                    }

                }

                )



            }

            VStack {
                Text("Mic增益: \(String(format: "%.1f", micAddVolume)) 倍")
                    .font(.headline)



                Slider(value: $micAddVolume, in: 1...30, step: 0.1,
                        onEditingChanged: { editing in

                    if !editing {

#if os(iOS)



                        CFNotificationCenterPostNotification(
                            cfCenter,
                            CFNotificationName("micAdd" as CFString),
                            nil,
                            nil,
                            true
                        )
#else
                        NotificationCenter.default
                            .post(
                                name: Notification.Name("micAdd"),
                                object: nil
                            )
#endif

                        sendlog(message: String(
                            format: "Mic增益更新: %.1f 倍",
                            micAddVolume
                        ))


                    }


                }

                )

            }


            VStack {

                Text("App音量: \(formatSliderPercent(volumeToPercentage(appVolume))) 原始:\(formatPreciseVolumePercent(appVolume))")
                    .font(.headline)



                Slider(
                    value:
                        Binding(
                    get: { volumeToPercentage(appVolume) },            // 從 appVolume 轉百分比
                    set: { newValue in

                             // 邊界保護，避免浮點誤差
                            if abs(newValue - 1.0) < volumeSliderStep {
                                appVolume = 1.0
                            } else if abs(newValue - 0.0) < volumeSliderStep {
                                appVolume = 0.0
                            } else {
                                appVolume = percentageToVolume(newValue)
                            }

                        }
                    )
                        , in: 0.0...1.0, step: volumeSliderStep,
                        onEditingChanged: { editing in

                    if !editing {



#if os(iOS)

                        CFNotificationCenterPostNotification(
                            cfCenter,
                            CFNotificationName(
                                "appVolumeChanged" as CFString
                            ),
                            nil,
                            nil,
                            true
                        )
#else
                        NotificationCenter.default
                            .post(
                                name: Notification.Name("appVolumeChanged"),
                                object: nil
                            )
#endif

                        sendlog(message: String(
                            format: "應用音量更新: %.5f%% (真實值: %.8f)",
                            volumeToPercentage(appVolume) * 100,
                            appVolume
                        ))

                    }

                }
                )




                // 標尺
                HStack {
                    Text("0%").font(.caption)
                    Spacer()
                    Text("25%").font(.caption)
                    Spacer()
                    Text("50%").font(.caption)
                    Spacer()
                    Text("75%").font(.caption)
                    Spacer()
                    Text("100%").font(.caption)
                }



                // 自繪進度條 (取代 ProgressView)
                SafeProgressBar(value: visualVolumeLevel(appVolume), color: .blue)
                    .padding(.vertical, 4)


            }



            VStack {
                // 顯示用：直接顯示真實音量百分比
                Text("Mic音量: \(formatSliderPercent(volumeToPercentage(micVolume))) 原始:\(formatPreciseVolumePercent(micVolume))")
                    .font(.headline)




                Slider(value:
                        Binding(
                    get: { volumeToPercentage(micVolume) },            // 從 micVolume 轉百分比
                    set: { newValue in

                           // 邊界保護，避免浮點誤差
                            if abs(newValue - 1.0) < volumeSliderStep {
                                micVolume = 1.0
                            } else if abs(newValue - 0.0) < volumeSliderStep {
                                micVolume = 0.0
                            } else {
                                micVolume = percentageToVolume(newValue)
                            }


                        }
                    )

                        , in: 0.0...1.0, step: volumeSliderStep,
                        onEditingChanged: { editing in

                    if !editing {
                        //let realVolume = percentageToVolume(Mic_percentage)
                        sendlog(message: String(
                            format: "麥克風音量更新: %.5f%% (真實值: %.8f)",
                            volumeToPercentage(micVolume) * 100,
                            micVolume
                        ))


#if os(iOS)

                        CFNotificationCenterPostNotification(
                            cfCenter,
                            CFNotificationName(
                                "micVolumeChanged" as CFString
                            ),
                            nil,
                            nil,
                            true
                        )

#else
                        NotificationCenter.default
                            .post(
                                name: Notification.Name("micVolumeChanged"),
                                object: nil
                            )
#endif
                    }

                }
                )




                // 標尺
                HStack {
                    Text("0%").font(.caption)
                    Spacer()
                    Text("25%").font(.caption)
                    Spacer()
                    Text("50%").font(.caption)
                    Spacer()
                    Text("75%").font(.caption)
                    Spacer()
                    Text("100%").font(.caption)
                }


                // 自繪進度條 (取代 ProgressView)
                SafeProgressBar(value: visualVolumeLevel(micVolume), color: .red)
                    .padding(.vertical, 4)

            }




            VStack(alignment: .leading) {
                Text("Mic Volume \(formatPreciseVolumePercent(Double(model.micVolumeLive)))")


                // 自繪進度條 (取代 ProgressView)
                SafeProgressBar(value: visualVolumeLevel(Double(model.micVolumeLive)), color: .red)
                    .padding(.vertical, 4)

            }
            VStack(alignment: .leading) {
                Text("App Volume \(formatPreciseVolumePercent(Double(model.appVolumeLive)))")

                // 自繪進度條 (取代 ProgressView)
                SafeProgressBar(value: visualVolumeLevel(Double(model.appVolumeLive)), color: .blue)
                    .padding(.vertical, 4)


            }
        }
        .padding()
    }
}
