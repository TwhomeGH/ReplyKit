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
            socketLog: defaults.bool(forKey: "EnableSocketlog"))
        guard let data = try? JSONEncoder().encode(config) else { return nil }
        defaults.set(data, forKey: storageKey)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString),
            nil, nil, true)
        return config
    }
}
