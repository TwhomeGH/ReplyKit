import Foundation
import CoreGraphics

enum OverlayAnchor: String, Codable, CaseIterable, Identifiable, Hashable {
    case topLeft
    case topCenter
    case topRight
    case centerLeft
    case center
    case centerRight
    case bottomLeft
    case bottomCenter
    case bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: return AppLanguage.localized("overlayAnchor.topLeft")
        case .topCenter: return AppLanguage.localized("overlayAnchor.topCenter")
        case .topRight: return AppLanguage.localized("overlayAnchor.topRight")
        case .centerLeft: return AppLanguage.localized("overlayAnchor.centerLeft")
        case .center: return AppLanguage.localized("overlayAnchor.center")
        case .centerRight: return AppLanguage.localized("overlayAnchor.centerRight")
        case .bottomLeft: return AppLanguage.localized("overlayAnchor.bottomLeft")
        case .bottomCenter: return AppLanguage.localized("overlayAnchor.bottomCenter")
        case .bottomRight: return AppLanguage.localized("overlayAnchor.bottomRight")
        }
    }

    func origin(container: CGSize, item: CGSize, marginX: CGFloat, marginY: CGFloat, offsetX: CGFloat, offsetY: CGFloat) -> CGPoint {
        let x: CGFloat
        switch self {
        case .topLeft, .centerLeft, .bottomLeft:
            x = marginX
        case .topCenter, .center, .bottomCenter:
            x = (container.width - item.width) * 0.5
        case .topRight, .centerRight, .bottomRight:
            x = container.width - item.width - marginX
        }

        let y: CGFloat
        switch self {
        case .topLeft, .topCenter, .topRight:
            y = marginY
        case .centerLeft, .center, .centerRight:
            y = (container.height - item.height) * 0.5
        case .bottomLeft, .bottomCenter, .bottomRight:
            y = container.height - item.height - marginY
        }

        return CGPoint(x: x + offsetX, y: y + offsetY)
    }
}

enum OverlayFontWeight: String, Codable, CaseIterable, Identifiable, Hashable {
    case regular
    case medium
    case bold

    var id: String { rawValue }

    var title: String {
        switch self {
        case .regular: return AppLanguage.localized("fontWeight.regular")
        case .medium: return AppLanguage.localized("fontWeight.medium")
        case .bold: return AppLanguage.localized("fontWeight.bold")
        }
    }
}

enum TimeOverlayFormat: String, Codable, CaseIterable, Identifiable, Hashable {
    case timeOnly
    case dateTime
    case elapsed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timeOnly: return AppLanguage.localized("timeFormat.timeOnly")
        case .dateTime: return AppLanguage.localized("timeFormat.dateTime")
        case .elapsed: return AppLanguage.localized("timeFormat.elapsed")
        }
    }

    var dateFormat: String {
        switch self {
        case .timeOnly: return "HH:mm:ss"
        case .dateTime: return "yyyy/MM/dd HH:mm:ss"
        case .elapsed: return "HH:mm:ss"
        }
    }
}

struct TimeOverlayConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var enabled: Bool = true
    var anchor: OverlayAnchor = .topRight
    var marginX: Double = 24
    var marginY: Double = 20
    var offsetX: Double = 0
    var offsetY: Double = 0
    var fontSize: Double = 16
    var fontWeight: OverlayFontWeight = .medium
    var textColorHex: String = "#FFFFFF"
    var backgroundEnabled: Bool = true
    var backgroundColorHex: String = "#000000"
    var backgroundOpacity: Double = 0.45
    var cornerRadius: Double = 6
    var paddingX: Double = 8
    var paddingY: Double = 5
    var format: TimeOverlayFormat = .dateTime
}

struct OverlaySceneConfig: Codable, Equatable {
    var version: Int = 1
    var enabled: Bool = false
    var time: TimeOverlayConfig = TimeOverlayConfig()
}

enum OverlayConfigStore {
    static let key = "OverlaySceneConfig"
    static let notificationName = "OverlaySceneConfigChanged"

    static func load(defaults: UserDefaults? = userDefaults) -> OverlaySceneConfig {
        guard let data = defaults?.data(forKey: key),
              let config = try? JSONDecoder().decode(OverlaySceneConfig.self, from: data) else {
            return OverlaySceneConfig()
        }
        return config
    }

    static func save(_ config: OverlaySceneConfig, defaults: UserDefaults? = userDefaults) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults?.set(data, forKey: key)
        defaults?.synchronize()
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString),
            nil,
            nil,
            true
        )
    }
}
