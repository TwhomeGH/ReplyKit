import CoreFoundation
import Foundation

/// 除錯開關的單一版本化快照；正常安裝走 App Group，側載仍保留舊事件 fallback。
struct RuntimeDebugConfig: Codable, Equatable, Sendable {
    static let storageKey = "runtimeDebugConfig"
    static let notificationName = "liveAPP.runtimeDebugConfig"

    var version: Int
    var rotateDebug: Bool
    var timeDebug: Bool
    var pipelineLog: Bool
    var socketLog: Bool
    var rotation: Int
    var rotateOriginal: Bool
    /// 舊 snapshot 沒有 rotation 欄位時為 false，避免套用預設 90° 覆蓋目前方向。
    var includesGeometry: Bool

    init(version: Int, rotateDebug: Bool, timeDebug: Bool, pipelineLog: Bool,
         socketLog: Bool, rotation: Int = 90, rotateOriginal: Bool = false,
         includesGeometry: Bool = false) {
        self.version = version
        self.rotateDebug = rotateDebug
        self.timeDebug = timeDebug
        self.pipelineLog = pipelineLog
        self.socketLog = socketLog
        self.rotation = rotation
        self.rotateOriginal = rotateOriginal
        self.includesGeometry = includesGeometry
    }

    private enum CodingKeys: String, CodingKey {
        case version, rotateDebug, timeDebug, pipelineLog, socketLog
        case rotation, rotateOriginal, includesGeometry
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        rotateDebug = try container.decodeIfPresent(Bool.self, forKey: .rotateDebug) ?? false
        timeDebug = try container.decodeIfPresent(Bool.self, forKey: .timeDebug) ?? false
        pipelineLog = try container.decodeIfPresent(Bool.self, forKey: .pipelineLog) ?? false
        socketLog = try container.decodeIfPresent(Bool.self, forKey: .socketLog) ?? false
        rotation = try container.decodeIfPresent(Int.self, forKey: .rotation) ?? 90
        rotateOriginal = try container.decodeIfPresent(Bool.self, forKey: .rotateOriginal) ?? false
        includesGeometry = try container.decodeIfPresent(Bool.self, forKey: .includesGeometry) ?? false
    }

    static func load(from defaults: UserDefaults?) -> RuntimeDebugConfig? {
        guard let data = defaults?.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(RuntimeDebugConfig.self, from: data)
    }

    /// 從既有 UserDefaults keys 產生新快照，版本只在成功發布時遞增。
    @discardableResult
    static func publish(to defaults: UserDefaults?) -> RuntimeDebugConfig? {
        guard let defaults else { return nil }
        let previous = load(from: defaults)
        let config = RuntimeDebugConfig(
            version: (previous?.version ?? 0) + 1,
            rotateDebug: defaults.bool(forKey: "EnableRotatelog"),
            timeDebug: defaults.bool(forKey: "EnableTimeDebug"),
            pipelineLog: defaults.bool(forKey: "EnablePipelineLog"),
            socketLog: defaults.bool(forKey: "EnableSocketlog"),
            rotation: defaults.object(forKey: "Rotate") as? Int ?? 90,
            rotateOriginal: defaults.object(forKey: "RotateOriginal") as? Bool ?? false,
            includesGeometry: true)
        guard let data = try? JSONEncoder().encode(config) else { return nil }
        defaults.set(data, forKey: storageKey)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString),
            nil, nil, true)
        return config
    }
}
