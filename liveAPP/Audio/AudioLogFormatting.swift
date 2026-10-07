import Foundation

/// 音訊日誌文字格式；無保存值、無佇列或 UI 副作用。
enum AudioLogFormatting {
    /// 將線性振幅倍率轉成百分比及振幅 dB（20 × log10）。
    /// 此值不是校準聲壓或實測 dBFS。零／負值沿用靜音表示；NaN／無限值標為無效。
    static func linearVolume(_ value: Float) -> String {
        let linear = Double(value)
        guard linear.isFinite else { return "invalid (non-finite)" }
        guard linear > 0 else { return "0.00000000 (0%, muted)" }
        return String(format: "%.8f (%.8f%%, %.2f dB)", locale: Locale(identifier: "en_US_POSIX"),
                      linear, linear * 100, 20 * log10(linear))
    }
}
