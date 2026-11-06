import Foundation

/// 讀取實際安裝包宣告，不以設定頁的預覽圖片推斷替換圖示已正確打包。
struct AppIconDiagnostics {
    let phoneNames: [String]
    let padNames: [String]
    let phoneFiles: [String]
    let padFiles: [String]
    let phoneIconName: String?
    let padIconName: String?
    let isPad: Bool
    let supported: Bool
    let current: String?
    let version: String?
    let build: String?
    let bundleID: String?
    let deviceFamily: String
    let phoneIconsPresent: Bool
    let padIconsPresent: Bool
    let buildID: String?
    let appRevision: String?
    let ciRun: String?

    init(info: [String: Any], isPad: Bool, supported: Bool, current: String?,
         build: BuildInformation = .current) {
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
        func iconName(_ key: String) -> String? {
            let icons = info[key] as? [String: Any]
            let alternatives = icons?["CFBundleAlternateIcons"] as? [String: Any]
            let personal = alternatives?["PersonalIcon"] as? [String: Any]
            return personal?["CFBundleIconName"] as? String
        }
        phoneIconName = iconName("CFBundleIcons")
        padIconName = iconName("CFBundleIcons~ipad")
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
        buildID = build.buildID
        appRevision = build.appRevision
        ciRun = build.ciRun
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
        let iconName = isPad ? padIconName : phoneIconName
        if iconName != nil {
            // asset catalog 的標準形式：圖示在 Assets.car，不需要獨立 PNG。
            return "安裝包有 PersonalIcon 與 CFBundleIconName；圖示在 Assets.car，缺少獨立 PNG 不代表缺漏。若系統仍不支援，需比對重簽前後 Info.plist／Assets.car 與裝置狀態。"
        }
        if (isPad ? padFiles : phoneFiles).isEmpty {
            return "安裝包有 PersonalIcon 名稱，但缺少 CFBundleIconName／CFBundleIconFiles 的實際圖示來源，系統目前不允許切換。"
        }
        return "安裝包有 PersonalIcon 宣告，但系統回報不支援。需比對重簽前後資源與裝置狀態，目前無法確定原因。"
    }

    var report: String {
        """
        version=\(version ?? "unknown") build=\(build ?? "unknown")
        bundle=\(bundleID ?? "unknown")
        appRevision=\(appRevision ?? "unknown") buildID=\(buildID ?? "unknown") ciRun=\(ciRun ?? "unknown")
        device=\(isPad ? "iPad" : "iPhone/其他") family=\(deviceFamily) supportsAlternateIcons=\(supported)
        current=\(current ?? "預設")
        CFBundleIcons.present=\(phoneIconsPresent)
        CFBundleIcons~ipad.present=\(padIconsPresent)
        CFBundleIcons.alternates=\(phoneNames.joined(separator: ","))
        CFBundleIcons~ipad.alternates=\(padNames.joined(separator: ","))
        iPhone.PersonalIcon.name=\(phoneIconName ?? "")
        iPad.PersonalIcon.name=\(padIconName ?? "")
        iPhone.PersonalIcon.files=\(phoneFiles.joined(separator: ","))
        iPad.PersonalIcon.files=\(padFiles.joined(separator: ","))
        """
    }
}
