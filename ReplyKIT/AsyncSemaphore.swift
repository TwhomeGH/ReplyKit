import Foundation

final class AsyncSemaphore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "AsyncSemaphore")
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.count = value
    }

    nonisolated func wait() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.count > 0 {
                    self.count -= 1
                    continuation.resume()
                } else {
                    self.waiters.append(continuation)
                }
            }
        }
    }

    nonisolated func signal() {
        queue.async {
            if let waiter = self.waiters.first {
                self.waiters.removeFirst()
                waiter.resume()
            } else {
                self.count += 1
            }
        }
    }
}
