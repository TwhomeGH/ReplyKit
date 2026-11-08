import Foundation

enum AVLagPersistenceMode: String, CaseIterable, Identifiable {
    case memoryOnly = "memory"
    case recentSessions = "recent5"

    var id: String { rawValue }
}

/// AV Lag 報告的保存偏好；預設不落地，避免一般使用者無意間累積檔案。
enum AVLagSettings {
    static let modeKey = "avLagPersistenceMode"
    static let segmentHoursKey = "avLagSegmentHours"
    static let longSessionSegmentsKey = "avLagLongSessionSegments"
    static let recentLimit = 5
    static let maxTotalBytes = 50 * 1024 * 1024
    static let sampleIntervalSeconds = 5

    private static var defaults: UserDefaults {
        #if os(iOS)
        userDefaults ?? .standard
        #else
        userDefaults
        #endif
    }

    static var mode: AVLagPersistenceMode {
        AVLagPersistenceMode(rawValue: defaults.string(forKey: modeKey) ?? "")
            ?? .memoryOnly
    }

    static var segmentHours: Int {
        let value = defaults.object(forKey: segmentHoursKey) as? Int ?? 4
        return min(8, max(1, value))
    }

    static var longSessionSegments: Bool {
        defaults.bool(forKey: longSessionSegmentsKey)
    }

    static var segmentDuration: TimeInterval {
        TimeInterval(segmentHours * 3600)
    }

    static var maxSamplesPerSegment: Int {
        max(1, segmentHours * 3600 / sampleIntervalSeconds)
    }
}
