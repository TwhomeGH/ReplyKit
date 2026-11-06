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
        self.isPad = isPad
        self.supported = supported
        self.current = current
    }

    /// 缺宣告與系統拒絕分開說明；無法由此判定是否為重簽工具造成。
    var explanation: String {
        if supported { return "系統支援切換內建圖示。" }
        let names = isPad ? padNames : phoneNames
        if !names.contains("PersonalIcon") {
            return "目前安裝包缺少此裝置的 PersonalIcon 宣告，請檢查 CI 產物及重新簽署後的 Info.plist；不能僅據此判定側載不支援。"
        }
        if (isPad ? padFiles : phoneFiles).isEmpty {
            return "安裝包有圖示名稱，但缺少此裝置的替換 PNG 檔案宣告，系統目前不允許切換。請使用補齊圖示尺寸的新版，再比對重簽前後宣告。"
        }
        return "安裝包有 PersonalIcon 宣告，但系統回報不支援。需比對重簽前後資源與裝置狀態，目前無法確定原因。"
    }

    var report: String {
        """
        device=\(isPad ? "iPad" : "iPhone/其他") supportsAlternateIcons=\(supported)
        current=\(current ?? "預設")
        CFBundleIcons.alternates=\(phoneNames.joined(separator: ","))
        CFBundleIcons~ipad.alternates=\(padNames.joined(separator: ","))
        iPhone.PersonalIcon.files=\(phoneFiles.joined(separator: ","))
        iPad.PersonalIcon.files=\(padFiles.joined(separator: ","))
        """
    }
}
