import Foundation

enum LogSeverity: String, CaseIterable {
    case info, success, warning, error
    var titleKey: String { "logs.level." + rawValue }
    var marker: String {
        switch self { case .info: return "·"; case .success: return "✓"; case .warning: return "⚠"; case .error: return "✕" }
    }
}

/// 舊文字日誌的顯示分類；原文保持不變，不以單一 error／dropped 字樣判斷失敗。
struct LogPresentation: Hashable {
    let severity: LogSeverity
    let source: String
    init(_ message: String) {
        let lower = message.lowercased()
        if lower.contains("[captureerror]") || lower.contains("publishphase=failed") ||
            message.contains("❌") || message.contains("失敗") || lower.contains("error:") {
            severity = .error
        } else if message.contains("重連") || message.contains("警告") || message.contains("回退") ||
                    lower.range(of: #"\bdropped=[1-9]\d*"#, options: .regularExpression) != nil {
            severity = .warning
        } else if lower.contains("publishphase=published") || message.contains("✅") ||
                    message.contains("成功") || message.contains("錄製完成") {
            severity = .success
        } else { severity = .info }
        if lower.contains("[recording") { source = "Recording" }
        else if lower.contains("[capture") || lower.contains("[screencapturekit]") { source = "Capture" }
        else if lower.contains("rtmp") { source = "RTMP" }
        else if lower.contains("socket") { source = "Socket" }
        else if lower.contains("tts") { source = "TTS" }
        else if lower.contains("[buildinfo]") { source = "BuildInfo" }
        else { source = "App" }
    }
    static let sources = ["App", "Capture", "RTMP", "Recording", "Socket", "TTS", "BuildInfo"]
    func matches(_ message: String, severityFilter: String, sourceFilter: String, query: String) -> Bool {
        (severityFilter == "all" || (severityFilter == "issues" ? severity == .warning || severity == .error : severity.rawValue == severityFilter)) &&
        (sourceFilter == "all" || source == sourceFilter) &&
        (query.isEmpty || message.localizedCaseInsensitiveContains(query))
    }
}
