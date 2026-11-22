import Foundation

/// 本機 socket 完成進度；不是對端 ACK，也不能證明伺服器已解碼。
struct CaptureSendProgress {
    private var generation: UInt64?
    private var completed = 0
    private var progressedAt = 0.0
    private var previousState = "unknown"

    /// 每輪取樣：有待送資料且十秒未完成才標記停滯；換線後重新建立基準。
    mutating func sample(generation: UInt64, completed: Int, queued: Int, failed: Int,
                         now: Double) -> (text: String, changed: Bool) {
        let reset = self.generation != generation
        let delta = reset ? 0 : max(0, completed - self.completed)
        if reset || delta > 0 || queued == 0 { progressedAt = now }
        let idle = max(0, now - progressedAt)
        let state = queued == 0 ? "queueEmpty" : (idle >= 10 ? "localSendStalled" : "pending")
        let changed = state != previousState
        self.generation = generation
        self.completed = completed
        previousState = state
        return ("generation=\(generation) baselineReset=\(reset) state=\(state) completedDeltaBytes=\(delta) queuedBytes=\(queued) noCompletionSeconds=\(idle) failedBatches=\(failed)", changed)
    }
}
