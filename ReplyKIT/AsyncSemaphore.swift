import Foundation

final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.count = value
    }

    func wait() async {
        lock.lock()
        if count > 0 {
            count -= 1
            lock.unlock()
            return
        }
        lock.unlock()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            waiters.append(cont)
            lock.unlock()
        }
    }

    func signal() {
        lock.lock()
        if let waiter = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            waiter.resume()
        } else {
            count += 1
            lock.unlock()
        }
    }
}
