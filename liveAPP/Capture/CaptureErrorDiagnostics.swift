import Foundation

/// 只輸出已知錯誤欄位；不傾印 userInfo 或 RTMP arguments。
enum CaptureErrorDiagnostics {
    static func sanitize(_ text: String, secrets: [String]) -> String {
        var result = text
        var tokens = secrets
        for secret in secrets {
            tokens.append(secret.removingPercentEncoding ?? secret)
            if let components = URLComponents(string: secret) {
                tokens += [components.user, components.password].compactMap { $0 }
                tokens += (components.queryItems ?? []).compactMap(\.value)
            }
            if let base = secret.split(separator: "?").first { tokens.append(String(base)) }
        }
        for token in Set(tokens).filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: token, with: "<redacted>")
        }
        result = result.replacingOccurrences(of: #"(?i)\b(?:rtmps?|https?)://[^\s\"<>]+"#, with: "<url>", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)(token|password|secret|key|signature|auth)\s*[=:]\s*[^\s,;]+"#, with: "$1=<redacted>", options: .regularExpression)
        return String(result.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").prefix(4096))
    }
    static func describe(_ error: Error, secrets: [String]) -> String {
        var parts = ["type=\(String(reflecting: type(of: error)))"]
        if Mirror(reflecting: error).displayStyle == .enum {
            parts.append("detail=\(String(describing: error))")
        }
        var current: NSError? = error as NSError
        var seen = Set<ObjectIdentifier>()
        for depth in 0..<4 {
            guard let item = current, seen.insert(ObjectIdentifier(item)).inserted else { break }
            parts.append("cause[\(depth)] domain=\(item.domain) code=\(item.code) description=\(item.localizedDescription)")
            if let reason = item.localizedFailureReason { parts.append("reason=\(reason)") }
            if let recovery = item.localizedRecoverySuggestion { parts.append("recovery=\(recovery)") }
            current = item.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return sanitize(parts.joined(separator: " | "), secrets: secrets)
    }
}
