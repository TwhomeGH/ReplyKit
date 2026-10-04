import Foundation

/// 單一消費端；容量按實際樣本 bytes 計算，慢消費時淘汰舊樣本，不逐幀建立 Task。
final class CaptureMailbox<Value: Sendable>: @unchecked Sendable {
    private struct Entry { let value: Value; let bytes: Int; let time: TimeInterval }
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
    func offer(_ value: Value, bytes size: Int) {
        lock.lock()
        let size = max(1, size)
        guard !closed, size <= budget else { dropped += 1; lock.unlock(); return }
        accepted += 1
        let now = clock()
        while let first = entries.first, now - first.time > age || bytes > budget - size {
            bytes -= entries.removeFirst().bytes; dropped += 1
        }
        if let waiter { self.waiter = nil; lock.unlock(); waiter.resume(returning: value); return }
        entries.append(Entry(value: value, bytes: size, time: now)); bytes += size
        lock.unlock()
    }
    func stream() -> AsyncStream<Value> {
        AsyncStream(unfolding: { await self.next() }, onCancel: { self.finish() })
    }
    private func next() async -> Value? {
        await withCheckedContinuation { continuation in
            lock.lock()
            let now = clock()
            while let first = entries.first, now - first.time > age {
                bytes -= entries.removeFirst().bytes; dropped += 1
            }
            if !entries.isEmpty {
                let first = entries.removeFirst(); bytes -= first.bytes
                lock.unlock(); continuation.resume(returning: first.value)
            } else if closed { lock.unlock(); continuation.resume(returning: nil) }
            else { precondition(waiter == nil); waiter = continuation; lock.unlock() }
        }
    }
    func finish() {
        lock.lock(); closed = true; entries.removeAll(); bytes = 0
        let pending = waiter; waiter = nil; lock.unlock(); pending?.resume(returning: nil)
    }
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        return "accepted=\(accepted) dropped=\(dropped) queued=\(entries.count) bytes=\(bytes)/\(budget)"
    }
}
