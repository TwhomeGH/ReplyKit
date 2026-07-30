import WidgetKit
import SwiftUI

@main
struct LiveActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        StreamActivityWidget()
    }
}

struct StreamActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StreamActivityAttributes.self) { state in
            StreamActivityLiveView(state: state, streamTitle: "")
        } dynamicIsland: { state in
            StreamActivityDynamicIsland(state: state, streamTitle: "")
        }
    }
}

struct StreamActivityDynamicIsland: DynamicIsland {
    var state: StreamActivityAttributes.ContentState
    var streamTitle: String

    var body: DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
            Label(state.elapsedTime, systemImage: "clock")
                .font(.caption)
        }
        DynamicIslandExpandedRegion(.trailing) {
            if !state.bitrate.isEmpty {
                Text(state.bitrate)
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
        DynamicIslandExpandedRegion(.bottom) {
            HStack {
                Text(streamTitle)
                    .font(.caption)
                Spacer()
                if let viewers = state.viewerCount {
                    Label("\(viewers)", systemImage: "person.2")
                        .font(.caption)
                }
            }
            .foregroundColor(.secondary)
        }
        DynamicIslandExpandedRegion(.center) {
            Text(state.elapsedTime)
                .font(.system(.title2, design: .monospaced))
        }
    }
}
