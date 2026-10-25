import Foundation

/// PCM 內容時長與來源時間對照；呼叫端負責同步，不保留音訊資料。
struct AudioTimelineObservation {
    private(set) var generation = 0
    private var format: String?
    private var firstPTS: Double?
    private var lastEnd: Double?
    private var frames: UInt64 = 0
    private var contentSeconds = 0.0
    private var discontinuities = 0
    private var invalid = 0

    /// frames 是 sample frames，不乘聲道數。格式或時基變更由 signature 開新世代。
    /// 大於一個 sample 的間隔／重疊只計數，不修正 PTS；spanMinusContent 非口型偏移。
    mutating func record(pts: Double, frames count: Int, rate: Double, signature: String) {
        guard pts.isFinite, rate.isFinite, rate > 0, count > 0 else { invalid += 1; return }
        if format != signature {
            generation += 1
            format = signature
            firstPTS = nil
            lastEnd = nil
            frames = 0
            contentSeconds = 0
            discontinuities = 0
        }
        if let end = lastEnd, abs(pts - end) > 1.5 / rate { discontinuities += 1 }
        if firstPTS == nil { firstPTS = pts }
        let duration = Double(count) / rate
        frames += UInt64(count)
        contentSeconds += duration
        lastEnd = pts + duration
    }

    /// 快照皆為目前格式世代；invalid 為此觀測器生命週期累計。
    var summary: String {
        func number(_ value: Double?) -> String { value.map { String(format: "%.6f", $0) } ?? "unknown" }
        let span = firstPTS.flatMap { first in lastEnd.map { $0 - first } }
        return "generation=\(generation) firstPTS=\(number(firstPTS)) lastEndPTS=\(number(lastEnd)) frames=\(frames) contentSeconds=\(number(contentSeconds)) spanSeconds=\(number(span)) spanMinusContentSeconds=\(number(span.map { $0 - contentSeconds })) discontinuities=\(discontinuities) invalid=\(invalid)"
    }
}
