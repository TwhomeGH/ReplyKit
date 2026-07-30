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
        ActivityConfiguration(for: StreamActivityAttributes.self) { context in
            StreamActivityLiveView(state: context.state, streamTitle: context.attributes.streamTitle)
        } dynamicIsland: { state in
            DynamicIsland {
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
                        Text(state.attributes.streamTitle)
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
            } compactLeading: {
                Label(state.elapsedTime, systemImage: "clock")
            } compactTrailing: {
                if !state.bitrate.isEmpty {
                    Text(state.bitrate)
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            } minimal: {
                Label(state.elapsedTime, systemImage: "clock")
            }
        }
    }
}
