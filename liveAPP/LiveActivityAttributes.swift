import ActivityKit
import SwiftUI

struct StreamActivityAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        var streamStatus: StreamStatus = .live
        var bitrate: String = ""
        var elapsedTime: String = "00:00:00"
        var viewerCount: Int?
        var cpuUsage: Double?
        var memoryUsage: Double?
    }

    var streamTitle: String = "直播中"
}

enum StreamStatus: Codable, Hashable {
    case live
    case ended
    case reconnecting(String)

    var label: String {
        switch self {
        case .live: return "Live"
        case .ended: return "已結束"
        case .reconnecting: return "重新連線中"
        }
    }
}

// MARK: - Lock Screen
struct StreamActivityLiveView: View {
    let state: StreamActivityAttributes.ContentState
    let streamTitle: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(streamTitle)
                    .font(.headline)
                Text(state.elapsedTime)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !state.bitrate.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Label(state.bitrate, systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                    if let viewers = state.viewerCount {
                        Label("\(viewers)", systemImage: "person.2")
                            .font(.caption)
                    }
                }
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Dynamic Island (需在 Xcode 中加入 ActivityKit framework 後啟用)
// struct StreamActivityDynamicIsland: DynamicIsland {
//     var state: StreamActivityAttributes.ContentState
//     var streamTitle: String
// 
//     var body: DynamicIsland {
//         DynamicIslandExpandedRegion(.leading) {
//             Label(state.elapsedTime, systemImage: "clock")
//                 .font(.caption)
//         }
//         DynamicIslandExpandedRegion(.trailing) {
//             if !state.bitrate.isEmpty {
//                 Text(state.bitrate)
//                     .font(.caption)
//                     .foregroundColor(.green)
//             }
//         }
//         DynamicIslandExpandedRegion(.bottom) {
//             HStack {
//                 Text(streamTitle)
//                     .font(.caption)
//                 Spacer()
//                 if let viewers = state.viewerCount {
//                     Label("\(viewers)", systemImage: "person.2")
//                         .font(.caption)
//                 }
//             }
//             .foregroundColor(.secondary)
//         }
//         DynamicIslandExpandedRegion(.center) {
//             Text(state.elapsedTime)
//                 .font(.system(.title2, design: .monospaced))
//         }
//     }
// }

// MARK: - ActivityManager
@MainActor
final class StreamActivityManager {
    static let shared = StreamActivityManager()

    private var currentActivity: Activity<StreamActivityAttributes>?
    private var updateTask: Task<Void, Never>?

    func startStreamActivity(streamTitle: String = "直播中") {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            sendlog(message: "Live Activity 權限未開啟，請至 設定 → ReplyKit → 即時動態 開啟")
            return
        }
        endStreamActivity()

        let attributes = StreamActivityAttributes(streamTitle: streamTitle)
        let state = StreamActivityAttributes.ContentState()
        let content = ActivityContent(state: state, staleDate: nil)

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            currentActivity = activity
            startPeriodicUpdates()
        } catch {
            sendlog(message: "Live Activity 啟動失敗: \(error)")
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

        guard let activity = currentActivity else { return }
        let state = activity.content.state
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(5)))
        }
        currentActivity = nil
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
}
