import Foundation

/// Metal 加工在途時間的聯集；重疊命令只計一次，與純 GPU 執行率不同。
final class ProcessingInFlightTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let id = UUID()
    private var count = 0
    private var activeSince: Double?
    private var total = 0.0
    private var previousTime: Double?
    private var previousTotal = 0.0
    private var submitted = 0
    private var completed = 0
    private var failed = 0
    private var lastPreparationMs = 0.0
    private var lastCompletionMs = 0.0
    private var angle = 0
    private var width = 0
    private var height = 0
    private var overlay = false
    private var resized = false

    /// 在提交命令前開始計時；準備耗時由呼叫端提供，不代表 CPU 使用率。
    func begin(at now: Double, preparationMs: Double, angle: Int, width: Int, height: Int, overlay: Bool, resized: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if count == 0 { activeSince = now }
        count += 1
        submitted += 1
        lastPreparationMs = preparationMs
        self.angle = angle
        self.width = width
        self.height = height
        self.overlay = overlay
        self.resized = resized
    }

    /// 僅實際完成回呼呼叫一次；watchdog 逾時不能提前扣除在途工作。
    func end(at now: Double, elapsedMs: Double, success: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return }
        count -= 1
        completed += 1
        if !success { failed += 1 }
        lastCompletionMs = elapsedMs
        if count == 0, let start = activeSince {
            total += max(0, now - start)
            activeSince = nil
        }
    }

    /// 唯一五秒回報者取得區間與摘要；首次只建立基準，重建實例不沿用舊區間。
    func sample(at now: Double = ProcessInfo.processInfo.systemUptime) -> (load: VideoProcessingLoadSnapshot?, summary: String) {
        lock.lock(); defer { lock.unlock() }
        let cumulative = total + (activeSince.map { max(0, now - $0) } ?? 0)
        var load: VideoProcessingLoadSnapshot?
        if let previousTime, now > previousTime {
            let interval = now - previousTime
            load = VideoProcessingLoadSnapshot(intervalSeconds: interval,
                busySeconds: min(interval, max(0, cumulative - previousTotal)), inFlight: count > 0)
        }
        if previousTime == nil || now > previousTime! {
            previousTime = now
            previousTotal = cumulative
        }
        return (load, "tracker=\(id) rotationDegrees=\(angle) resized=\(resized) canvas=\(width)x\(height) overlayEncoded=\(overlay) submitted=\(submitted) completed=\(completed) failed=\(failed) inFlight=\(count) preparationMs=\(lastPreparationMs) submitToCompletionMs=\(lastCompletionMs)")
    }
}
