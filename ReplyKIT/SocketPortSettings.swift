import Foundation

// Keep this file identical in the app and broadcast extension targets.
enum SocketPortSettings {
    static let defaultPort: UInt16 = 9322
    static let groupID = "group.nuclear.liveAPP"
    static let key = "socketListenPort"

    static var canCustomize: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil
    }

    static var port: UInt16 {
        guard canCustomize,
              let defaults = UserDefaults(suiteName: groupID),
              let value = UInt16(exactly: defaults.integer(forKey: key)),
              value >= 1024 else { return defaultPort }
        return value
    }

    static func save(_ port: UInt16) {
        guard canCustomize else { return }
        UserDefaults(suiteName: groupID)?.set(Int(port), forKey: key)
    }
}
