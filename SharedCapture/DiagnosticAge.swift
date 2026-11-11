import Foundation

/// 診斷時間差的人類可讀格式；保留一秒內的小數，避免全部截成 0 秒。
enum DiagnosticAge {
    static func text(_ seconds: TimeInterval) -> String {
        let age = max(0, seconds)
        if age < 0.1 {
            return "剛剛"
        }
        if age < 10 {
            return String(format: "%.1f 秒", age)
        }
        let total = Int(age)
        if total < 60 {
            return "\(total) 秒"
        }
        let minutes = total / 60
        let remainder = total % 60
        return remainder == 0 ? "\(minutes) 分" : "\(minutes) 分 \(remainder) 秒"
    }
}
