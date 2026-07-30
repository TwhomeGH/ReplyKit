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
