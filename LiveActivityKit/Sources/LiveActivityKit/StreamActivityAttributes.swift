import Foundation
import ActivityKit

public struct StreamActivityAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        public var streamStatus: StreamStatus = .live
        public var bitrate: String = ""
        /// 系統計時顯示的固定起點；舊版資料缺少時沿用 elapsedTime。
        public var startedAt: Date?
        /// 結束後凍結計時的時間點。
        public var endedAt: Date?
        /// 摘要取樣時間，不表示系統實際呈現時間。
        public var updatedAt: Date?
        public var elapsedTime: String = "00:00:00"
        public var viewerCount: Int?
        public var cpuUsage: Double?
        public var memoryUsage: Double?

        public init() {}

        public init(
            streamStatus: StreamStatus = .live,
            bitrate: String = "",
            elapsedTime: String = "00:00:00",
            viewerCount: Int? = nil,
            cpuUsage: Double? = nil,
            memoryUsage: Double? = nil
        ) {
            self.streamStatus = streamStatus
            self.bitrate = bitrate
            self.elapsedTime = elapsedTime
            self.viewerCount = viewerCount
            self.cpuUsage = cpuUsage
            self.memoryUsage = memoryUsage
        }
    }

    public var streamTitle: String

    public init(streamTitle: String = "直播中") {
        self.streamTitle = streamTitle
    }
}
