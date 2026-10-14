import Foundation

/// 單一消費端；容量按實際樣本 bytes 計算，慢消費時淘汰舊樣本，不逐幀建立 Task。
final class CaptureMailbox<Value: Sendable>: @unchecked Sendable {
    private struct Entry { let value: Value; let bytes: Int; let time: TimeInterval; let priority: Int }
    private let lock = NSLock()
    private let budget: Int
    private let age: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private var entries: [Entry] = []
    private var bytes = 0
    private var closed = false
    private var waiter: CheckedContinuation<Value?, Never>?
    private var accepted = 0
    private var dropped = 0
    init(budget: Int, age: TimeInterval = 0.1,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.budget = max(0, budget); self.age = max(0, age); self.clock = clock
    }
    /// 嘗試入列；容量不足先淘汰最低優先序，優先序相同時先淘汰較舊樣本。
    /// - Parameters:
    ///   - value: 要交付的樣本。
    ///   - size: 估計容量，單位 bytes。
    ///   - priority: 保留優先序；預設 0 維持先進先淘汰，錄製音訊使用 1。
    func offer(_ value: Value, bytes size: Int, priority: Int = 0) {
        lock.lock()
        let size = max(1, size)
        guard !closed, size <= budget else { dropped += 1; lock.unlock(); return }
        let now = clock()
        while let first = entries.first, now - first.time > age {
            bytes -= entries.removeFirst().bytes; dropped += 1
        }
        while bytes > budget - size {
            guard let lowest = entries.map(\.priority).min(), lowest <= priority,
                  let index = entries.firstIndex(where: { $0.priority == lowest }) else {
                dropped += 1
                lock.unlock()
                return
            }
            bytes -= entries.remove(at: index).bytes
            dropped += 1
        }
        accepted += 1
        if let waiter { self.waiter = nil; lock.unlock(); waiter.resume(returning: value); return }
        entries.append(Entry(value: value, bytes: size, time: now, priority: priority)); bytes += size
        lock.unlock()
    }
    func stream() -> AsyncStream<Value> {
        AsyncStream(unfolding: { await self.next() }, onCancel: { self.finish() })
    }
    private func next() async -> Value? {
        await withCheckedContinuation { continuation in
            lock.lock()
            let now = clock()
            while !closed, let first = entries.first, now - first.time > age {
                bytes -= entries.removeFirst().bytes; dropped += 1
            }
            if !entries.isEmpty {
                let first = entries.removeFirst(); bytes -= first.bytes
                lock.unlock(); continuation.resume(returning: first.value)
            } else if closed { lock.unlock(); continuation.resume(returning: nil) }
            else { precondition(waiter == nil); waiter = continuation; lock.unlock() }
        }
    }
    /// 預設停止即丟棄；檔案錄製可選擇保留已接受的尾端樣本直到消費完成。
    func finish(discardPending: Bool = true) {
        lock.lock(); closed = true
        if discardPending { entries.removeAll(); bytes = 0 }
        let pending = waiter; waiter = nil; lock.unlock(); pending?.resume(returning: nil)
    }

    /// 日誌詳情
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        return "accepted=\(accepted) dropped=\(dropped) queued=\(entries.count) bytes=\(bytes)/\(budget)"
    }
}
