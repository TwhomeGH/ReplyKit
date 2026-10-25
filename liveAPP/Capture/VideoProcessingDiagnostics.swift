import Foundation

/// 每幀只保存純量；摘要讀取時才建立字串，降低影片 worker 配置成本。
struct VideoProcessingFrameInfo: CustomStringConvertible {
    var rotateLeft = false
    var fills = false
    var sourceWidth = 0
    var sourceHeight = 0
    var outputWidth = 0
    var outputHeight = 0
    var overlay = false
    var overlayDegraded = false
    var overlayPrepareMs = 0.0
    var renderMs = 0.0
    var poolLimit = 0
    var poolExhausted = false
    var sourceColorSpace = false
    var description: String {
        "rotateLeft=\(rotateLeft) fills=\(fills) source=\(sourceWidth)x\(sourceHeight) canvas=\(outputWidth)x\(outputHeight) overlay=\(overlay) overlayDegraded=\(overlayDegraded) overlayPrepareMs=\(overlayPrepareMs) renderCallMs=\(renderMs) poolLimit=\(poolLimit) colorPolicy=\(sourceColorSpace ? "sourceRGB" : "sRGBFallback")"
    }
}

/// 以 48 MiB 像素預算推算池上限，最多六張；不代表整個程序記憶體上限。
enum VideoProcessingBudget {
    static func limit(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { return nil }
        // 預留每列 256-byte 對齊；實際驅動配置仍需量測。
        let rowBytes = ((width * 4 + 255) / 256) * 256
        let count = (48 * 1024 * 1024) / (rowBytes * height)
        return count > 0 ? min(6, count) : nil
    }
}

/// 單一加工器的固定大小統計；worker 寫入、診斷工作讀取，鎖內不進行影像處理或日誌 I/O。
final class VideoProcessingDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var activeSince: Double?
    private var completedBusySeconds = 0.0
    private var previousLoadTime: Double?
    private var previousBusySeconds = 0.0

    /// 單 worker 每次加工開始呼叫；在途工作也能被週期取樣觀測。
    func begin(at now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard now.isFinite, activeSince == nil else { return }
        activeSince = now
    }

    /// 由唯一診斷工作每五秒取樣；首次僅建立基準，讀取 UI 不會消耗區間。
    func sampleLoad(at now: Double = ProcessInfo.processInfo.systemUptime) -> VideoProcessingLoadSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard now.isFinite else { return nil }
        let cumulative = completedBusySeconds + (activeSince.map { max(0, now - $0) } ?? 0)
        guard let previous = previousLoadTime else {
            previousLoadTime = now
            previousBusySeconds = cumulative
            return nil
        }
        guard now > previous else { return nil }
        let interval = now - previous
        let busy = min(interval, max(0, cumulative - previousBusySeconds))
        previousLoadTime = now
        previousBusySeconds = cumulative
        return VideoProcessingLoadSnapshot(intervalSeconds: interval, busySeconds: busy,
                                           inFlight: activeSince != nil)
    }

    private var attempts = 0
    private var processed = 0
    private var bypassed = 0
    private var failed = 0
    private var lastMilliseconds = 0.0
    private var maxMilliseconds = 0.0
    private var lastInputPTS: Double?
    private var lastOutputPTS: Double?
    private var lastError: String?
    private var configuration = VideoProcessingFrameInfo()
    private var degraded = 0
    private var poolExhausted = 0
    private var totalMilliseconds = 0.0
    private var over16Milliseconds = 0

    /// 保存同一次加工的輸入／輸出 PTS 與結果。耗時是呼叫端經過時間，不是純 GPU 執行時間。
    func record(inputPTS: Double, outputPTS: Double?, elapsed: Double,
                bypass: Bool, configuration: VideoProcessingFrameInfo, error: String?,
                completedAt now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        if let start = activeSince {
            completedBusySeconds += max(0, now - start)
            activeSince = nil
        }
        attempts += 1
        if error != nil { failed += 1 }
        else if bypass { bypassed += 1 }
        else { processed += 1 }
        lastMilliseconds = max(0, elapsed) * 1000
        maxMilliseconds = max(maxMilliseconds, lastMilliseconds)
        lastInputPTS = inputPTS.isFinite ? inputPTS : nil
        lastOutputPTS = outputPTS.flatMap { $0.isFinite ? $0 : nil }
        lastError = error
        self.configuration = configuration
        if configuration.overlayDegraded { degraded += 1 }
        if configuration.poolExhausted { poolExhausted += 1 }
        totalMilliseconds += lastMilliseconds
        if lastMilliseconds > 1000.0 / 60 { over16Milliseconds += 1 }
    }

    /// 累計計數及最近同筆時間；成功表示本機加工完成，尚未包含 Mixer 或編碼。
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        func number(_ value: Double?) -> String { value.map { String(format: "%.6f", $0) } ?? "unknown" }
        return "attempts=\(attempts) processed=\(processed) bypassed=\(bypassed) failed=\(failed) lastMs=\(number(lastMilliseconds)) maxMs=\(number(maxMilliseconds)) inputPTS=\(number(lastInputPTS)) outputPTS=\(number(lastOutputPTS)) overlayDegraded=\(degraded) poolExhausted=\(poolExhausted) meanMs=\(number(attempts > 0 ? totalMilliseconds / Double(attempts) : nil)) over16_67ms=\(over16Milliseconds) lastError=\(lastError ?? "none") \(configuration)"
    }
}
