import Foundation

/// 讀取實際安裝包宣告，不以設定頁的預覽圖片推斷替換圖示已正確打包。
struct AppIconDiagnostics {
    let phoneNames: [String]
    let padNames: [String]
    let phoneFiles: [String]
    let padFiles: [String]
    let isPad: Bool
    let supported: Bool
    let current: String?
    let version: String?
    let build: String?
    let bundleID: String?
    let deviceFamily: String
    let phoneIconsPresent: Bool
    let padIconsPresent: Bool

    init(info: [String: Any], isPad: Bool, supported: Bool, current: String?) {
        func names(_ key: String) -> [String] {
            let icons = info[key] as? [String: Any]
            let alternatives = icons?["CFBundleAlternateIcons"] as? [String: Any]
            return alternatives?.keys.sorted() ?? []
        }
        phoneNames = names("CFBundleIcons")
        padNames = names("CFBundleIcons~ipad")
        func files(_ key: String) -> [String] {
            let icons = info[key] as? [String: Any]
            let alternatives = icons?["CFBundleAlternateIcons"] as? [String: Any]
            let personal = alternatives?["PersonalIcon"] as? [String: Any]
            return personal?["CFBundleIconFiles"] as? [String] ?? []
        }
        phoneFiles = files("CFBundleIcons")
        padFiles = files("CFBundleIcons~ipad")
        version = info["CFBundleShortVersionString"] as? String
        build = info["CFBundleVersion"] as? String
        bundleID = info["CFBundleIdentifier"] as? String
        let families = (info["UIDeviceFamily"] as? [Any])?.compactMap { value -> String? in
            if let number = value as? NSNumber { return number.stringValue }
            if let number = value as? Int { return String(number) }
            return nil
        }
        deviceFamily = families?.joined(separator: ",") ?? "unknown"
        phoneIconsPresent = info["CFBundleIcons"] is [String: Any]
        padIconsPresent = info["CFBundleIcons~ipad"] is [String: Any]
        self.isPad = isPad
        self.supported = supported
        self.current = current
    }

    /// 區分「整個 CFBundleIcons 不存在」與「有宣告但缺 PersonalIcon／PNG」。
    var explanation: String {
        if supported { return "系統支援切換內建圖示。" }
        let key = isPad ? "CFBundleIcons~ipad" : "CFBundleIcons"
        let present = isPad ? padIconsPresent : phoneIconsPresent
        let names = isPad ? padNames : phoneNames
        if !present {
            return "目前安裝包的 \(key) 不存在，不是只有替換 PNG 缺失。請先確認 App 版本／建置是否包含替換圖示，或重簽後 Info.plist 是否被換掉。"
        }
        if !names.contains("PersonalIcon") {
            return "目前安裝包有 \(key)，但缺少 PersonalIcon；建置設定或 asset catalog 可能沒有帶入，請比對 CI archive 與重簽後的 Info.plist。"
        }
        if (isPad ? padFiles : phoneFiles).isEmpty {
            return "安裝包有圖示名稱，但缺少此裝置的替換 PNG 檔案宣告，系統目前不允許切換。請使用補齊圖示尺寸的新版，再比對重簽前後宣告。"
        }
        return "安裝包有 PersonalIcon 宣告，但系統回報不支援。需比對重簽前後資源與裝置狀態，目前無法確定原因。"
    }

    var report: String {
        """
        version=\(version ?? "unknown") build=\(build ?? "unknown")
        bundle=\(bundleID ?? "unknown")
        device=\(isPad ? "iPad" : "iPhone/其他") family=\(deviceFamily) supportsAlternateIcons=\(supported)
        current=\(current ?? "預設")
        CFBundleIcons.present=\(phoneIconsPresent)
        CFBundleIcons~ipad.present=\(padIconsPresent)
        CFBundleIcons.alternates=\(phoneNames.joined(separator: ","))
        CFBundleIcons~ipad.alternates=\(padNames.joined(separator: ","))
        iPhone.PersonalIcon.files=\(phoneFiles.joined(separator: ","))
        iPad.PersonalIcon.files=\(padFiles.joined(separator: ","))
        """
    }
}
