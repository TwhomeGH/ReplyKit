import WidgetKit
import SwiftUI
import LiveActivityKit

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
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StreamActivityElapsedView(state: context.state)
                }
            } compactLeading: {
                StreamActivityElapsedView(state: context.state)
            } compactTrailing: {
                Text("")
            } minimal: {
                StreamActivityElapsedView(state: context.state)
            }
        }
    }
}
