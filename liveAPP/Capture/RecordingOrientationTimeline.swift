import Foundation

struct RecordingOrientationEvent: Equatable, Sendable {
    let seconds: Double
    let orientation: Int
}

/// 僅保留方向轉換，不持有影像 buffer。保留上限避免異常來源無限累積。
final class RecordingOrientationTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var firstTime: Double?
    private var lastTime: Double?
    private var events: [RecordingOrientationEvent] = []
    private var invalid = false
    private var missing = 0
    func observe(seconds: Double, orientation: Int?) {
        lock.lock(); defer { lock.unlock() }
        guard seconds.isFinite else { invalid = true; return }
        if let lastTime, seconds < lastTime { invalid = true; return }
        lastTime = seconds
        if firstTime == nil { firstTime = seconds }
        guard let orientation, (1...8).contains(orientation) else { missing += 1; return }
        let offset = max(0, seconds - (firstTime ?? seconds))
        if let last = events.last, offset < last.seconds { invalid = true; return }
        guard events.last?.orientation != orientation else { return }
        if let last = events.last, last.seconds == offset {
            events[events.count - 1] = RecordingOrientationEvent(seconds: offset, orientation: orientation)
            return
        }
        guard events.count < 4096 else { invalid = true; return }
        // 第一個有效方向套用至起點，避免一開始附件尚未到達而留下錯向片段。
        events.append(RecordingOrientationEvent(seconds: events.isEmpty ? 0 : offset, orientation: orientation))
    }
    func snapshot() -> (events: [RecordingOrientationEvent], reliable: Bool, missing: Int) {
        lock.lock(); defer { lock.unlock() }
        return (events, !invalid && !events.isEmpty, missing)
    }
}
