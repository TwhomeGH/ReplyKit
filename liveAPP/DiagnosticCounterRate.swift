import Foundation

/// 累計計數的每秒速率；首次、倒退、重設或過久未取樣均回傳未知。
enum DiagnosticCounterRate {
    /// - Parameters:
    ///   - current: 本次累計值；nil 表示來源未提供。
    ///   - previous: 同一 session／介面的前次累計值。
    ///   - elapsed: 單調時鐘間隔秒數。
    /// - Returns: 每秒速率；超過 15 秒的間隔不補成連續資料。
    static func value(current: UInt64?, previous: UInt64?, elapsed: Double) -> Double? {
        guard let current, let previous, current >= previous,
              elapsed.isFinite, elapsed > 0, elapsed <= 15 else { return nil }
        return Double(current - previous) / elapsed
    }
}
