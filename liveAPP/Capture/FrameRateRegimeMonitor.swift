import Foundation

/// 追蹤 Mixer 輸出與實際編碼交付的幀率比例；只用來偵測持續的輸出降級。
///
/// 靜態畫面會讓兩邊同時下降，因此不告警；只有來源仍持續輸出、但編碼交付
/// 連續低於一半時才視為 regime change。這是觀測狀態，不會修改編碼設定。
struct FrameRateRegimeMonitor: Sendable {
    /// 目前判定；warmingUp 與 sourceIdle 都不是「正常」的同義詞。
    enum State: String, Sendable {
        case warmingUp
        case normal
        case degraded
        case sourceIdle
        case unknown
    }

    /// 狀態變化事件；只在進入 degraded 或恢復 normal 時回傳。
    enum Event: Equatable, Sendable {
        case regimeChange
        case recovered
    }

    /// 對外可讀的快照；nil 代表該次取樣沒有可用速率。
    struct Snapshot: Equatable, Sendable {
        let state: State
        let sourceFPS: Double?
        let outputFPS: Double?
        let ratio: Double?
        let consecutiveLow: Int
        let alertCount: Int

        /// 單行摘要；未知值不寫成 0。
        var summary: String {
            func number(_ value: Double?) -> String {
                value.map { String(format: "%.1f", $0) } ?? "unknown"
            }
            return "state=\(state.rawValue) sourceFPS=\(number(sourceFPS)) "
                + "outputFPS=\(number(outputFPS)) ratio=\(number(ratio)) "
                + "consecutiveLow=\(consecutiveLow) alerts=\(alertCount)"
        }
    }

    private(set) var snapshot = Snapshot(
        state: .warmingUp, sourceFPS: nil, outputFPS: nil, ratio: nil,
        consecutiveLow: 0, alertCount: 0)
    private var samples = 0
    private var consecutiveLow = 0
    private var consecutiveRecovered = 0
    private var alertCount = 0
    /// 一旦進入 degraded，sourceIdle 不應該清除告警狀態。
    private var isDegraded = false

    /// 來源至少要有這麼多 fps 才可能是「輸出掉半」，避免把靜態 hold 當異常。
    private let minimumSourceFPS = 10.0
    /// 交付／來源低於此比例算掉半；保留一點編碼器正常的少量差異。
    private let degradedRatio = 0.55
    /// 恢復需要高於此比例，避免在門檻附近反覆切換。
    private let recoveredRatio = 0.75
    /// 連續幾個五秒取樣才告警；第一個取樣只用來建立基準。
    private let warmupSamples = 2
    private let requiredLowSamples = 3
    private let requiredRecoverySamples = 3

    /// 記錄一次取樣。
    /// - Parameters:
    ///   - sourceFPS: Mixer 實際輸出影格率。
    ///   - outputFPS: 實際編碼交付影格率。
    /// - Returns: 只在狀態進入 degraded 或恢復 normal 時回傳事件。
    mutating func record(sourceFPS: Double?, outputFPS: Double?) -> Event? {
        samples += 1
        let source = sourceFPS.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let output = outputFPS.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }

        guard let source, let output else {
            snapshot = Snapshot(state: .unknown, sourceFPS: source, outputFPS: output,
                                ratio: nil, consecutiveLow: consecutiveLow,
                                alertCount: alertCount)
            consecutiveLow = 0
            consecutiveRecovered = 0
            return nil
        }

        let ratio = source > 0 ? output / source : nil
        guard samples > warmupSamples else {
            snapshot = Snapshot(state: .warmingUp, sourceFPS: source, outputFPS: output,
                                ratio: ratio, consecutiveLow: 0,
                                alertCount: alertCount)
            return nil
        }

        guard source >= minimumSourceFPS else {
            // 來源本身沒有新影格（靜態 hold、背景節流）；輸出低是預期行為。
            consecutiveLow = 0
            consecutiveRecovered = 0
            snapshot = Snapshot(state: .sourceIdle, sourceFPS: source, outputFPS: output,
                                ratio: ratio, consecutiveLow: 0,
                                alertCount: alertCount)
            return nil
        }

        guard let ratio else {
            snapshot = Snapshot(state: .unknown, sourceFPS: source, outputFPS: output,
                                ratio: nil, consecutiveLow: consecutiveLow,
                                alertCount: alertCount)
            return nil
        }

        if ratio <= degradedRatio {
            consecutiveLow += 1
            consecutiveRecovered = 0
            if consecutiveLow >= requiredLowSamples, !isDegraded {
                isDegraded = true
                alertCount += 1
                snapshot = Snapshot(state: .degraded, sourceFPS: source, outputFPS: output,
                                    ratio: ratio, consecutiveLow: consecutiveLow,
                                    alertCount: alertCount)
                return .regimeChange
            }
        } else if ratio >= recoveredRatio {
            consecutiveLow = 0
            consecutiveRecovered += 1
            if consecutiveRecovered >= requiredRecoverySamples, isDegraded {
                isDegraded = false
                consecutiveRecovered = 0
                snapshot = Snapshot(state: .normal, sourceFPS: source, outputFPS: output,
                                    ratio: ratio, consecutiveLow: 0,
                                    alertCount: alertCount)
                return .recovered
            }
        } else {
            consecutiveLow = 0
            consecutiveRecovered = 0
        }

        snapshot = Snapshot(state: isDegraded ? .degraded : .normal,
                            sourceFPS: source, outputFPS: output, ratio: ratio,
                            consecutiveLow: consecutiveLow, alertCount: alertCount)
        return nil
    }
}
