import Foundation

/// 週期把記憶體明細寫入日誌，讓 footprint 的成長可以歸因（「誰在漲」）。
///
/// 只讀取 `DeviceInfo.memoryBreakdown`（單次 `task_vm_info`）與幾個已知會累積的計數器，
/// 不改動任何狀態，純觀測；用於追查像「廣播中 footprint 持續爬升」這類問題。
///
/// 欄位：
/// - footprint：jetsam 真正採計的實際佔用（該看的數字）。
/// - internal／compressed：footprint = internal + compressed。
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

    private func sample() {
        let m = DeviceInfo.memoryBreakdown
        let url = URLCache.shared
        let line = String(
            format: "[Memory] footprint=%.1f internal=%.1f compressed=%.1f external=%.1f reusable=%.1f purgeable=%.1f resident=%.1f avail=%.1f | urlCacheMem=%.0fKB urlCacheDisk=%.0fKB",
            m.footprintMB, m.internalMB, m.compressedMB, m.externalMB, m.reusableMB,
            m.purgeableVolatileMB, m.residentMB, m.availableMB,
            Double(url.currentMemoryUsage) / 1024, Double(url.currentDiskUsage) / 1024
        )
        sendlog(message: line)
    }
}
