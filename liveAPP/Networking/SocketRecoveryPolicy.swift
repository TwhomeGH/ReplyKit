import Foundation

/// listener 恢復決策；不接觸 Network 或佇列，可獨立驗證所有狀態。
enum SocketRecoveryPolicy {
    enum ListenerState: CaseIterable { case missing, starting, waiting, ready, failed, cancelled }
    enum Action: Equatable { case stopped, blocked, deferred, preserve, coalesced, schedule }

    /// 被動恢復不得推翻停止或端口占用；正在啟動／等待網路的 listener 保留。
    static func action(state: ListenerState, wantsRunning: Bool, blocked: Bool,
                       changingPort: Bool, retryScheduled: Bool) -> Action {
        guard wantsRunning else { return .stopped }
        guard !changingPort else { return .deferred }
        guard !blocked else { return .blocked }
        switch state {
        case .starting, .waiting, .ready: return .preserve
        case .missing, .failed, .cancelled: return retryScheduled ? .coalesced : .schedule
        }
    }

    /// 使用單調時鐘，冷卻期間延後重試，不直接丟棄最後一次恢復要求。
    static func delay(now: TimeInterval, lastAttempt: TimeInterval?, minimum: TimeInterval) -> TimeInterval {
        max(0, minimum, lastAttempt.map { 3 - (now - $0) } ?? 0)
    }
}
