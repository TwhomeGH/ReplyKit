import Testing
@testable import liveAPP

struct SocketSendQueuePolicyTests {
    @Test func acceptsWithinLimits() {
        #expect(SocketSendQueuePolicy.decision(
            pendingBytes: 0, pendingPayloads: 0, newBytes: 1024) == .enqueue)
        #expect(SocketSendQueuePolicy.decision(
            pendingBytes: SocketSendQueuePolicy.maxPendingBytes - 10,
            pendingPayloads: SocketSendQueuePolicy.maxPendingPayloads - 1,
            newBytes: 10) == .enqueue)
    }

    @Test func disconnectsWhenByteLimitWouldExceed() {
        #expect(SocketSendQueuePolicy.decision(
            pendingBytes: SocketSendQueuePolicy.maxPendingBytes,
            pendingPayloads: 0, newBytes: 1) == .disconnect)
        #expect(SocketSendQueuePolicy.decision(
            pendingBytes: 0, pendingPayloads: 0,
            newBytes: SocketSendQueuePolicy.maxPendingBytes + 1) == .disconnect)
    }

    @Test func disconnectsWhenPayloadCountWouldExceed() {
        #expect(SocketSendQueuePolicy.decision(
            pendingBytes: 0,
            pendingPayloads: SocketSendQueuePolicy.maxPendingPayloads,
            newBytes: 1) == .disconnect)
    }

    @Test func rejectsNegativeInputs() {
        #expect(SocketSendQueuePolicy.decision(pendingBytes: -1, pendingPayloads: 0,
                                               newBytes: 1) == .disconnect)
        #expect(SocketSendQueuePolicy.decision(pendingBytes: 0, pendingPayloads: -1,
                                               newBytes: 1) == .disconnect)
        #expect(SocketSendQueuePolicy.decision(pendingBytes: 0, pendingPayloads: 0,
                                               newBytes: -1) == .disconnect)
    }
}
