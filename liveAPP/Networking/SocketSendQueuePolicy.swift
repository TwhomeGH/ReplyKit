import Foundation

/// 一般 Socket 訊息的每連線待送上限；超限視為慢速連線，直接關閉而不是丟訊息。
enum SocketSendQueuePolicy {
    static let maxPendingBytes = 1_048_576
    static let maxPendingPayloads = 128

    enum Decision: Equatable {
        case enqueue
        case disconnect
    }

    static func decision(pendingBytes: Int, pendingPayloads: Int, newBytes: Int) -> Decision {
        guard pendingBytes >= 0, pendingPayloads >= 0, newBytes >= 0 else { return .disconnect }
        if pendingPayloads + 1 > maxPendingPayloads { return .disconnect }
        if pendingBytes + newBytes > maxPendingBytes { return .disconnect }
        return .enqueue
    }
}
