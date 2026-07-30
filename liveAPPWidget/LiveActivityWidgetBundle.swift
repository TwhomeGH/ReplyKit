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
        } dynamicIsland: { context in
            let s = context.state
            let title = context.attributes.streamTitle
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(s.elapsedTime, systemImage: "clock")
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Group {
                        if s.bitrate.isEmpty {
                            EmptyView()
                        } else {
                            Text(s.bitrate)
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(title)
                            .font(.caption)
                        Spacer()
                        if let viewers = s.viewerCount {
                            Label("\(viewers)", systemImage: "person.2")
                                .font(.caption)
                        }
                    }
                    .foregroundColor(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.elapsedTime)
                        .font(.system(.title2, design: .monospaced))
                }
            } compactLeading: {
                Label(s.elapsedTime, systemImage: "clock")
            } compactTrailing: {
                Group {
                    if s.bitrate.isEmpty {
                        EmptyView()
                    } else {
                        Text(s.bitrate)
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
            } minimal: {
                Label(s.elapsedTime, systemImage: "clock")
            }
        }
    }
}
