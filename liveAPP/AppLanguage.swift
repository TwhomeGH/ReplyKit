import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHant
    case en
    case ja

    var id: String { rawValue }

    var localeIdentifier: String? {
        switch self {
        case .system: return nil
        case .zhHant: return "zh-Hant"
        case .en: return "en"
        case .ja: return "ja"
        }
    }

    var titleKey: String {
        switch self {
        case .system: return "appLanguage.system"
        case .zhHant: return "appLanguage.zhHant"
        case .en: return "appLanguage.en"
        case .ja: return "appLanguage.ja"
        }
    }

    var locale: Locale {
        guard let localeIdentifier else { return .autoupdatingCurrent }
        return Locale(identifier: localeIdentifier)
    }

    static var selected: AppLanguage {
        let rawValue = userDefaults?.string(forKey: "AppLanguage") ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    static func localized(_ key: String) -> String {
        guard let identifier = selected.localeIdentifier,
              let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return String(localized: String.LocalizationValue(key))
        }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
