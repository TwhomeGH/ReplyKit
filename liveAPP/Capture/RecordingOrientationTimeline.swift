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

/// 手動方向以原始錄影像素為基準，設定在開始擷取時固定。
enum RecordingOrientationPolicy: String, CaseIterable, Identifiable, Sendable {
    case automatic, none, left, right, halfTurn
    var id: String { rawValue }
    var titleKey: String { "recording.orientation." + rawValue }
    func outputOrientation(for source: Int) -> Int {
        switch self {
        case .none: return 1
        case .left: return 8
        case .right: return 6
        case .halfTurn: return 3
        case .automatic:
            // SCStream 附件描述來源方向；輸出需套用反向旋轉。
            // 鏡射與 180 度為自反，只有 90／270 度需要互換。
            return source == 6 ? 8 : (source == 8 ? 6 : source)
        }
    }
}
