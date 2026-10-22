import Foundation
#if os(iOS)
import UIKit
#endif

/// 週期把記憶體明細寫入日誌，用來定位 footprint 成長的時間；無法單憑分類判定持有物件。
///
/// 只讀取 `DeviceInfo.memoryBreakdown`（單次 `task_vm_info`）與幾個已知會累積的計數器，
/// 不改動任何狀態，純觀測；用於追查像「廣播中 footprint 持續爬升」這類問題。
///
/// 欄位：
/// - footprint：jetsam 真正採計的實際佔用（該看的數字）。
/// - internal／compressed：獨立的 VM 分類，不能直接相加視為 footprint。
/// - external：檔案映射（框架/靜態庫），多可回收，**不計入** footprint。
/// - reusable／purgeable：可重用／可清除頁。
/// - resident：實體駐留（含可回收），僅對照。
/// - avail：距 jetsam 上限的可用量（`os_proc_available_memory`）。
/// - urlCacheMem/Disk：`URLCache.shared` 記憶體／磁碟用量。
final class MemorySampler {
    static let shared = MemorySampler()

    private let queue = DispatchQueue(label: "com.nuclear.liveAPP.memorySampler", qos: .utility)
    private var timer: DispatchSourceTimer?

    private init() {}

    /// 在生命週期邊界取樣，與週期日誌使用同一條序列佇列。
    func checkpoint(_ reason: String) {
        queue.async { [weak self] in self?.sample(reason: reason) }
    }

    /// 開始週期取樣；重複呼叫安全（已啟動則忽略）。
    func start(interval: TimeInterval = 30) {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(5))
            t.setEventHandler { [weak self] in self?.sample() }
            self.timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func sample(reason: String = "periodic") {
        let m = DeviceInfo.memoryBreakdown
        let url = URLCache.shared
        let line = String(
            format: "[Memory] footprint=%.1f internal=%.1f compressed=%.1f external=%.1f reusable=%.1f purgeable=%.1f resident=%.1f avail=%.1f | urlCacheMem=%.0fKB urlCacheDisk=%.0fKB",
            m.footprintMB, m.internalMB, m.compressedMB, m.externalMB, m.reusableMB,
            m.purgeableVolatileMB, m.residentMB, m.availableMB,
            Double(url.currentMemoryUsage) / 1024, Double(url.currentDiskUsage) / 1024
        )
        sendlog(message: line)
        #if os(iOS)
        // UI 狀態在 MainActor 讀取，不從背景佇列讀取 ObservableObject。
        Task { @MainActor in
            let capture = CaptureCoordinator.shared
            let pip = PIPService.diagnosticInstance?.resourceDiagnosticSummary ?? "pip=notInitialized"
            let tts = TTSService.diagnosticInstance?.resourceDiagnosticSummary ?? "tts=notInitialized"
            let appState: String
            switch UIApplication.shared.applicationState {
            case .active: appState = "active"
            case .inactive: appState = "inactive"
            case .background: appState = "background"
            @unknown default: appState = "unknown"
            }
            let comparison = IdleMemoryComparison.shared.observe(
                footprint: m.footprintMB, captureBusy: capture.isBusy,
                replayLive: !LPConfig.shared.StreamEnded, reason: reason)
            sendlog(message: "[IdleResources] reason=\(reason) \(comparison) uptime=\(Int(ProcessInfo.processInfo.systemUptime)) app=\(appState) footprintMB=\(String(format: "%.1f", m.footprintMB)) \(capture.resourceDiagnosticSummary) \(pip) \(tts) replayKitStatusIsLive=\(!LPConfig.shared.StreamEnded) statusIsNotProcessProof=true")
        }
        #endif
    }
}

/// 在主 actor 維護本程序基準；沿用採樣，不增加背景執行或定時器。
@MainActor
final class IdleMemoryComparison {
    static let shared = IdleMemoryComparison()
    private let processID = UUID()
    private let startedAt: TimeInterval

    init(startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) { self.startedAt = startedAt }
    private var everBusy = false
    private var wasBusy = false
    private var baseline: Double?
    private var lastBusyFootprint: Double?
    private var stoppedAt: TimeInterval?
    private var milestones: Set<Int> = []

    /// 冷啟動滿 60 秒仍未觀察到開播才建立基準；停止後以實際採樣時間標記里程碑。
    /// ReplayKit 僅是最後已知狀態，不能以此證明擴展程序已結束。
    func observe(footprint: Double, captureBusy: Bool, replayLive: Bool, reason: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String {
        let busy = captureBusy || replayLive
        if busy {
            everBusy = true
            lastBusyFootprint = footprint
            stoppedAt = nil
            milestones = []
        } else {
            if !everBusy && baseline == nil && now - startedAt >= 60 { baseline = footprint }
            if wasBusy { stoppedAt = now }
        }
        wasBusy = busy
        let elapsed = stoppedAt.map { now - $0 }
        let due = [30, 60, 120].filter { !milestones.contains($0) && (elapsed ?? -1) >= Double($0) }
        milestones.formUnion(due)
        func number(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "unknown" }
        return "process=\(processID) everObservedCapture=\(everBusy) coldIdleBaselineMB=\(number(baseline)) deltaBaselineMB=\(number(baseline.map { footprint - $0 })) stopElapsedSeconds=\(number(elapsed)) deltaLastBusyMB=\(number(elapsed == nil ? nil : lastBusyFootprint.map { footprint - $0 })) reachedStopSeconds=\(due)"
    }
}
