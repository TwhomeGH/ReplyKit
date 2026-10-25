import Foundation

/// SCStream 回呼入口摘要；只保存有限種類的純量，不持有媒體樣本。
/// 所有更新與讀取以同一把鎖保護，支援影音回呼並行。
final class CaptureCallbackDiagnostics: @unchecked Sendable {
    enum Track: String, CaseIterable { case video, audio, mic, unknown }
    enum Outcome: String { case offered, invalid, notReady, missingStatus, nonComplete, missingImage, unknownType }
    private struct Counters {
        var callbacks = 0
        var outcomes: [Outcome: Int] = [:]
        var states: [String: Int] = [:]
        var lastArrival: Double?
        var maxGap = 0.0
        var firstPTS: Double?
        var firstArrival: Double?
        var lastPTS: Double?
        var regressions = 0
        var invalidPTS = 0
        var lastDelta: Double?
        var minDelta: Double?
        var maxDelta: Double?
    }
    private let lock = NSLock()
    private var tracks: [Track: Counters] = [:]

    /// arrival 與 pts 皆以秒表示；delta 是 host clock 減來源 PTS，未驗證共同時基前不可稱為延遲。
    /// offered 只表示已嘗試交給 mailbox，是否接受仍以 mailbox 計數為準。
    func record(track: Track, outcome: Outcome, state: String?, arrival: Double, pts: Double) {
        lock.lock()
        defer { lock.unlock() }
        var value = tracks[track] ?? Counters()
        if value.firstArrival == nil { value.firstArrival = arrival }
        value.callbacks += 1
        value.outcomes[outcome, default: 0] += 1
        if let state { value.states[state, default: 0] += 1 }
        if let previous = value.lastArrival { value.maxGap = max(value.maxGap, arrival - previous) }
        value.lastArrival = arrival
        if pts.isFinite {
            if value.firstPTS == nil { value.firstPTS = pts }
            if let previous = value.lastPTS, pts < previous { value.regressions += 1 }
            value.lastPTS = pts
            let delta = arrival - pts
            value.lastDelta = delta
            value.minDelta = min(value.minDelta ?? delta, delta)
            value.maxDelta = max(value.maxDelta ?? delta, delta)
        } else {
            value.invalidPTS += 1
            value.lastDelta = nil
        }
        tracks[track] = value
    }

    /// 累計摘要與距最後回呼秒數；nil 顯示 unknown，零回呼不假裝成零延遲。
    func summary(now: Double) -> String {
        lock.lock()
        defer { lock.unlock() }
        func number(_ value: Double?) -> String { value.map { String(format: "%.6f", $0) } ?? "unknown" }
        return Track.allCases.map { track in
            let value = tracks[track] ?? Counters()
            let outcomes = value.outcomes.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ",")
            let states = value.states.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
            return "\(track.rawValue){callbacks=\(value.callbacks) firstArrival=\(number(value.firstArrival)) firstPTS=\(number(value.firstPTS)) outcomes=[\(outcomes)] states=[\(states)] idleSeconds=\(number(value.lastArrival.map { max(0, now - $0) })) maxCallbackGapSeconds=\(number(value.maxGap)) lastPTS=\(number(value.lastPTS)) regress=\(value.regressions) invalidPTS=\(value.invalidPTS) hostMinusPTSSeconds=\(number(value.lastDelta)) minHostMinusPTSSeconds=\(number(value.minDelta)) maxHostMinusPTSSeconds=\(number(value.maxDelta))}"
        }.joined(separator: " ")
    }
}
