import Foundation

/// 贊助每頁的進場／停留／退場時間軸；時間以單調時鐘計算，不按幀數累加。
enum PIPAdAnimation {
    static let transitionSeconds = 0.35
    /// 回傳 0...1 可見比例；elapsed 與 duration 均為秒。
    static func visibility(elapsed: Double, duration: Double) -> Double {
        guard elapsed.isFinite, duration.isFinite, duration > 0 else { return 0 }
        let edge = min(transitionSeconds, duration / 2)
        let fraction = max(0, min(1, min(elapsed, duration - elapsed) / edge))
        return fraction * fraction * (3 - 2 * fraction)
    }
    /// 是否需要動畫更新率；無效時長不啟動動畫。
    static func isTransitioning(elapsed: Double, duration: Double) -> Bool {
        guard elapsed.isFinite, duration.isFinite, duration > 0 else { return false }
        return elapsed < min(transitionSeconds, duration / 2) || duration - elapsed <= transitionSeconds
    }

    /// 停留低頻仍須在退場開始時喚醒，避免跨過整段淡出；回傳秒數。
    static func nextInterval(elapsed: Double, duration: Double, proposed: Double) -> Double {
        guard elapsed.isFinite, duration.isFinite, duration > 0 else { return proposed }
        let exitStart = duration - min(transitionSeconds, duration / 2)
        if elapsed < exitStart { return min(proposed, max(0.001, exitStart - elapsed)) }
        return proposed
    }
}
