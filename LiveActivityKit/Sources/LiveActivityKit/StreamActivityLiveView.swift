import SwiftUI

// MARK: - Lock Screen
public struct StreamActivityLiveView: View {
    let state: StreamActivityAttributes.ContentState
    let streamTitle: String

    public init(state: StreamActivityAttributes.ContentState, streamTitle: String) {
        self.state = state
        self.streamTitle = streamTitle
    }

    public var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(streamTitle.isEmpty ? "直播中" : streamTitle)
                    .font(.headline)
                StreamActivityElapsedView(state: state)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()
            if let updated = state.updatedAt {
                Text(updated, style: .time).font(.caption2).foregroundColor(.secondary)
                    .accessibilityLabel("摘要更新時間")
            }


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

/// 使用系統計時呈現經過時間，不必每秒更新 Activity 內容。
public struct StreamActivityElapsedView: View {
    private let state: StreamActivityAttributes.ContentState

    /// - Parameter state: 含固定開播時間的快照；舊資料以原文字顯示。
    public init(state: StreamActivityAttributes.ContentState) { self.state = state }

    public var body: some View {
        if let start = state.startedAt {
            if let end = state.endedAt {
                Text(Self.elapsed(max(0, end.timeIntervalSince(start))))
            } else {
                Text(start, style: .timer).monospacedDigit()
            }
        } else {
            Text(state.elapsedTime.isEmpty ? "00:00:00" : state.elapsedTime)
        }
    }

    /// 結束狀態使用固定文字，避免移除前繼續跳秒。
    private static func elapsed(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}
