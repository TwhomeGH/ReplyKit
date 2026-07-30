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


