import Foundation

/// 保護 App 共用 Audio Session，PiP/TTS 不得覆蓋擷取期間的錄音模式。
final class CaptureAudioOwnership: @unchecked Sendable {
    static let shared = CaptureAudioOwnership()
    private let lock = NSRecursiveLock()
    private var captured = false
    func begin() { lock.lock(); captured = true; lock.unlock() }
    func end() { lock.lock(); captured = false; lock.unlock() }
    func performUnlessCaptured(_ action: () throws -> Void) rethrows {
        lock.lock(); defer { lock.unlock() }
        guard !captured else { return }
        try action()
    }
}
