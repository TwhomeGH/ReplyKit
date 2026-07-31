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
                Text(state.elapsedTime.isEmpty ? "00:00:00" : state.elapsedTime)
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
