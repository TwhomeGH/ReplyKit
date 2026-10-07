import ReplayKit
import SwiftUI
import Combine
import os
import Foundation

let logger = Logger(subsystem: "nuclear.liveAPP", category: "extension")

let cfCenter = CFNotificationCenterGetDarwinNotifyCenter()


#if os(iOS)
let userDefaults: UserDefaults? = UserDefaults(
    suiteName: "group.nuclear.liveAPP"
) ?? .standard

#else
let userDefaults: UserDefaults = .standard
#endif



/// 寫入既有共用偏好，不在此主動通知擴展。
func setUserDefault<T>(_ value: T, forKey key: String) {
#if os(iOS)
    userDefaults?.set(value, forKey: key)
#else
    userDefaults.set(value, forKey: key)
#endif
}

/// 依指定型別讀取偏好，保留 UserDefaults 數值預設與可選回傳語意。
func getUserDefault<T>(forKey key: String) -> T? {
#if os(iOS)

    let defaults = userDefaults
    switch T.self {
    case is Float.Type:
        return defaults?.float(forKey: key) as? T
    case is Double.Type:
        return defaults?.double(forKey: key) as? T
    case is Int.Type:
        return defaults?.integer(forKey: key) as? T
    case is Bool.Type:
        return defaults?.bool(forKey: key) as? T
    default:
        return defaults?.value(forKey: key) as? T
    }
    #else

    guard let userDefaults = userDefaults else { return nil }

    let defaults = userDefaults
    switch T.self {
    case is Float.Type:
        return defaults.float(forKey: key) as? T
    case is Double.Type:
        return defaults.double(forKey: key) as? T
    case is Int.Type:
        return defaults.integer(forKey: key) as? T
    case is Bool.Type:
        return defaults.bool(forKey: key) as? T
    default:
        return defaults.value(forKey: key) as? T
    }



    #endif
}
