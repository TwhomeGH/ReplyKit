import Foundation
import SwiftUI
import Combine

/// 擴展回報的套用結果；revision 為該 session 成功套用的順序，不代表音量實測。
struct ReplayVolumeApplied: Decodable {
    let schema: Int
    let session: String
    let revision: Int
    let status: String
    let reportedAt: Double
    let app: Float?
    let mic: Float?
    var micGain: Float? = nil
}

@MainActor
final class LiveVolumeModel: ObservableObject {
    static let shared = LiveVolumeModel()   // 全局共用單例

    @Published var micVolumeLive: Float = 0.0
    @Published var appVolumeLive: Float = 0.0

    @Published private(set) var replayApplied: ReplayVolumeApplied?

    /// 跨連線延遲資料依回報時間與 session 內版本拒收；不覆蓋本機擷取。
    func reportReplayApplied(_ report: ReplayVolumeApplied) {
        guard captureSession == nil, report.schema == 1, report.reportedAt.isFinite,
              report.revision >= 0 else { return }
        if let previous = replayApplied {
            guard report.reportedAt > previous.reportedAt else { return }
            if report.session == previous.session, report.revision < previous.revision { return }
        }
        replayApplied = report
    }

    /// 只把新鮮、與目前需求相符的回覆標為已套用；回報缺席不冒充成功。
    func replayApplicationStatus(channel: String, desired: Double, now: Date) -> String {
        guard let report = replayApplied else { return "尚無擴展套用回報（舊版可能不支援）" }
        guard report.status != "stopped", !LPConfig.shared.StreamEnded else { return "擴展已停止" }
        guard now.timeIntervalSince1970 - report.reportedAt < 12 else { return "套用回報已過期，等待重新同步" }
        guard report.status == "applied" else { return "擴展同步失敗／尚未就緒，保留原設定" }
        let actual = channel == "micGain" ? report.micGain : (channel == "app" ? report.app : report.mic)
        guard let actual, actual.isFinite, abs(Double(actual) - desired) < 0.000001 else {
            return "等待擴展套用新設定"
        }
        return "擴展 Mixer 已套用 · 版本 \(report.revision)"
    }

    /// 本機擷取優先持有回報權；nil 表示接受舊版 ReplayKit 傳輸。
    private var captureSession: String?
    @Published private(set) var source = "ReplayKit"
    @Published private(set) var mixedVolume: Float?
    @Published private(set) var sampledAt: [String: Date] = [:]
    @Published private(set) var stopped = false
    /// Mixer 已接受的線性增益；不代表遠端播放驗證，也不提供分軌輸出實測。
    @Published private(set) var appliedGains: [String: Float] = [:]

    /// 僅接受當前擷取世代的套用回報，避免停止後的延遲工作污染新 session。
    func reportAppliedGains(_ session: String, app: Float, mic: Float?) {
        guard captureSession == session, !stopped else { return }
        appliedGains = ["app": app]
        appliedGains["mic"] = mic
    }

    private var visibleViews: Set<UUID> = []
    var monitoringVisible: Bool { !visibleViews.isEmpty }

    /// 多視窗各自登記，避免其中一個關閉便停用其他視窗的監測。
    func setVisible(_ visible: Bool, id: UUID) {
        if visible { visibleViews.insert(id) } else { visibleViews.remove(id) }
    }

    /// 開始本機 session，清除上一來源的值與時間。
    func beginCapture(_ session: String) {
        replayApplied = nil
        captureSession = session
        source = "ScreenCaptureKit"
        stopped = false
        appliedGains = [:]
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
        appliedGains = [:]
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



