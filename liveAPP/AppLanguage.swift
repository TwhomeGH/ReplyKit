import Foundation

/// 用於應用語言枚舉
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

    /// 本地化翻譯 由xcstrings清單內
    /// - Parameter key:對應xcstring
    /// - Returns: 翻譯後的值
    static func localized(_ key: String) -> String {
        guard let identifier = selected.localeIdentifier,
              let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return String(localized: String.LocalizationValue(key))
        }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
