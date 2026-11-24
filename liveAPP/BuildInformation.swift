import Foundation

/// 只讀取隨產物封裝的快照，頁面、複製內容與啟動日誌共用。
struct BuildInformation: Decodable, Sendable {
    var schemaVersion = 1
    var buildID: String?
    var appRevision: String?
    /// 建置來源分支、標籤或 commit；detached HEAD 不顯示成 HEAD。
    var appRef: String?
    /// release／branch-test／ci／local；舊 JSON 沒有此欄位時為未知。
    var appChannel: String?
    var appDirty: Bool?
    var appUntrackedCount: Int?
    var appModifiedCount: Int?
    var builtAt: String?
    var source: String?
    var configuration: String?
    var platform: String?
    var xcode: String?
    var sdk: String?
    var ciRun: String?
    var ciAttempt: String?
    var haishinRevision: String?
    var haishinVersion: String?
    var haishinCheckoutRevision: String?
    var haishinCheckoutDirty: Bool?
    var haishinCheckoutUntrackedCount: Int?
    var haishinCheckoutModifiedCount: Int?
    var haishinVerification: String?

    static let current: Self = {
        let data = Bundle.main.url(forResource: "BuildInfo", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        return decode(data)
    }()
    static func decode(_ data: Data?) -> Self {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data), value.schemaVersion == 1 else { return Self() }
        return value
    }
    private func text(_ value: String?) -> String { value.flatMap { $0.isEmpty ? nil : $0 } ?? "未知" }
    private func modifications(dirty: Bool?, untracked: Int?, modified: Int?) -> String {
        guard let dirty else { return "未知" }
        guard dirty else { return "乾淨" }
        var parts: [String] = []
        if let modified, modified > 0 { parts.append("已追蹤 \(modified)") }
        if let untracked, untracked > 0 { parts.append("未追蹤 \(untracked)") }
        return parts.isEmpty ? "有未提交修改" : "有未提交修改（\(parts.joined(separator: "、"))）"
    }
    var verification: String {
        switch haishinVerification {
        case "matched": return haishinCheckoutDirty == true ? "commit 相符，但套件有本機修改" : (haishinCheckoutDirty == false ? "checkout 與鎖定 commit 相符" : "commit 相符，修改狀態未知")
        case "mismatch": return "checkout 與鎖定 commit 不同"
        case "unverified": return "僅取得鎖定值，尚未核對 checkout"
        default: return "未知：未取得套件鎖定資訊"
        }
    }
    var channel: String {
        switch appChannel {
        case "release": return "正式發布"
        case "branch-test": return "分支測試"
        case "ci": return "CI 建置"
        case "local": return "本機建置"
        case let value?: return value
        case nil: return "未知"
        }
    }
    var rows: [(String, String)] {
        [
            ("App commit", text(appRevision)),
            ("建置分支／標籤", text(appRef)),
            ("建置通道", channel),
            ("App 原始碼狀態", modifications(dirty: appDirty, untracked: appUntrackedCount, modified: appModifiedCount)),
            ("HaishinKit 鎖定 commit", text(haishinRevision)),
            ("HaishinKit checkout commit", text(haishinCheckoutRevision)),
            ("HaishinKit 版本標籤", text(haishinVersion)),
            ("HaishinKit 原始碼狀態", modifications(dirty: haishinCheckoutDirty, untracked: haishinCheckoutUntrackedCount, modified: haishinCheckoutModifiedCount)),
            ("套件核對結果", verification),
            ("產物識別碼", text(buildID)),
            ("建置時間（UTC）", text(builtAt)),
            ("建置來源", text(source)),
            ("建置組態", text(configuration)),
            ("平台", text(platform)),
            ("Xcode 版本代碼", text(xcode)),
            ("SDK", text(sdk)),
            ("CI 執行編號", text(ciRun)),
            ("CI 重跑次數", text(ciAttempt))
        ]
    }
    var report: String { rows.map { "\($0.0)：\($0.1)" }.joined(separator: "\n") }
}
