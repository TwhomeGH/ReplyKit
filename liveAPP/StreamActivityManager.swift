import ActivityKit
import SwiftUI

// MARK: - ActivityManager
@MainActor
final class StreamActivityManager: ObservableObject {
    static let shared = StreamActivityManager()

    @Published private(set) var isActivityActive = false
    @Published var lastError: String? {
        didSet {
            if lastError != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.lastError = nil
                }
            }
        }
    }

    private var currentActivity: Activity<StreamActivityAttributes>? {
        didSet { isActivityActive = currentActivity != nil }
    }
    private var updateTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    func startStreamActivity(streamTitle: String = "直播中") {
        let auth = ActivityAuthorizationInfo()
        sendlog(message: "Live Activity: areActivitiesEnabled=\(auth.areActivitiesEnabled)")
        guard auth.areActivitiesEnabled else {
            lastError = "權限未開啟：請至 設定 → ReplyKit → 即時動態 開啟"
            sendlog(message: "Live Activity 權限未開啟，請至 設定 → ReplyKit → 即時動態 開啟")
            return
        }
        endStreamActivity()

        let attributes = StreamActivityAttributes(streamTitle: streamTitle)
        let state = StreamActivityAttributes.ContentState()
        let content = ActivityContent(state: state, staleDate: nil)

        Task {
            do {
                let activity = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
                currentActivity = activity
                startPeriodicUpdates()
                observeDismiss(for: activity)
                sendlog(message: "Live Activity 已啟動")
            } catch {
                lastError = "啟動失敗: \(error.localizedDescription)"
                sendlog(message: "Live Activity 啟動失敗: \(error)")
            }
        }
    }

    func updateStreamActivity(_ state: StreamActivityAttributes.ContentState) {
        guard let activity = currentActivity else { return }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(30))
        Task {
            await activity.update(content)
        }
    }

    func endStreamActivity() {
        updateTask?.cancel()
        updateTask = nil
        dismissTask?.cancel()
        dismissTask = nil

        guard let activity = currentActivity else { return }
        currentActivity = nil
        Task {
            let state = activity.content.state
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(5)))
        }
    }

    private func startPeriodicUpdates() {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)

                guard let activity = self?.currentActivity else { break }
                let totalSeconds = Int(LPConfig.shared.lastStreamTime)
                let hours = totalSeconds / 3600
                let minutes = (totalSeconds % 3600) / 60
                let seconds = totalSeconds % 60
                let elapsed = String(format: "%02d:%02d:%02d", hours, minutes, seconds)

                var status: StreamStatus = .live
                if LPConfig.shared.StreamEnded {
                    status = .ended
                } else if LPConfig.shared.isReconnecting {
                    status = .reconnecting(LPConfig.shared.reconnectStatus)
                }

                let updated = StreamActivityAttributes.ContentState(
                    streamStatus: status,
                    bitrate: LPConfig.shared.streamBitrate,
                    elapsedTime: elapsed,
                    viewerCount: LPConfig.shared.streamViewerCount,
                    cpuUsage: DeviceInfo.cpuUsagePercent,
                    memoryUsage: DeviceInfo.appMemoryMB
                )
                let content = ActivityContent(state: updated, staleDate: Date().addingTimeInterval(30))
                await activity.update(content)
            }
        }
    }

    private func observeDismiss(for activity: Activity<StreamActivityAttributes>) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                if state == .dismissed {
                    self?.lastError = "即時動態已被手動清除"
                    self?.endStreamActivity()
                    break
                }
            }
        }
    }
}
