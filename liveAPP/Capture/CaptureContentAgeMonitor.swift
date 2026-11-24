import Foundation

/// 擷取端內容年齡閘門：只依真正的抓幀時間丟棄過期影格。
///
/// 這不是佇列容量限制，也不是 `frameInterval` 幀率上限；它回答的是
/// 「這張畫面在送到 mixer 前，內容已經舊了多久」。沒有可信的
/// `captureHostTime` 時不丟幀，只計入 `clockMissing`，避免把 ReplayKit
/// 的 presentation time 誤當成抓幀時間。
final class CaptureContentAgeMonitor: @unchecked Sendable {
    struct Decision {
        /// 是否應在進入 queue／GPU 前丟棄這張影格。
        let drop: Bool
        /// 需要寫入日誌的事件；沒有事件時為 nil。
        let event: String?
    }

    private let lock = NSLock()
    private let threshold: TimeInterval
    private let warmup: TimeInterval
    private var firstSampleAt: Double?
    private var samples = 0
    private var dropped = 0
    private var clockMissing = 0
    private var lastAge: Double?
    private var maxAge: Double?
    private var lastDropEventAt: Double?

    /// - Parameters:
    ///   - threshold: 超過此內容年齡才丟棄，預設 200ms。
    ///   - warmup: 開始取樣後的寬限期，避免第一個舊 timestamp 造成黑畫面。
    init(threshold: TimeInterval = 0.2, warmup: TimeInterval = 1.0) {
        self.threshold = threshold.isFinite ? max(0, threshold) : 0.2
        self.warmup = warmup.isFinite ? max(0, warmup) : 1.0
    }

    /// 評估一張影格的內容年齡。`age` 必須與 `now` 使用同一個單調時鐘。
    func evaluate(age: Double?, now: Double) -> Decision {
        lock.lock()
        defer { lock.unlock() }
        samples &+= 1
        if firstSampleAt == nil {
            firstSampleAt = now
        }
        guard let age, age.isFinite else {
            clockMissing &+= 1
            return Decision(drop: false, event: nil)
        }
        let nonNegative = max(0, age)
        lastAge = nonNegative
        maxAge = max(maxAge ?? nonNegative, nonNegative)
        let warmedUp = warmup <= max(0, now - (firstSampleAt ?? now))
        guard warmedUp, threshold <= nonNegative else {
            return Decision(drop: false, event: nil)
        }

        dropped &+= 1
        guard lastDropEventAt == nil || 30 <= now - (lastDropEventAt ?? now) else {
            return Decision(drop: true, event: nil)
        }
        lastDropEventAt = now
        let text = String(
            format: "event=contentAgeDrop age=%.3f threshold=%.3f contentAgeDropped=%d samples=%d clockMissing=%d",
            nonNegative, threshold, dropped, samples, clockMissing)
        return Decision(drop: true, event: text)
    }

    /// 供低頻摘要使用；未知值保留 unknown，不假裝成 0。
    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        func number(_ value: Double?) -> String {
            value.map { String(format: "%.3f", $0) } ?? "unknown"
        }
        return "samples=\(samples) contentAgeDropped=\(dropped) threshold=\(String(format: "%.3f", threshold)) lastAge=\(number(lastAge)) maxAge=\(number(maxAge)) clockMissing=\(clockMissing)"
    }
}
