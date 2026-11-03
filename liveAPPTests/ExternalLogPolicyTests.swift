import Testing
@testable import liveAPP

struct ExternalLogPolicyTests {
    @Test func extensionMessagesIncludeSingleAndBatchLogs() {
        for type in ["log", "logbatch", "videoHealth", "audioHealth", "reconnectStatus"] {
            #expect(ExternalLogPolicy.marksExtension(type))
        }
        #expect(!ExternalLogPolicy.marksExtension("subscribeExternalLogs"))
        #expect(!ExternalLogPolicy.marksExtension("externalLogBatch"))
        #expect(!ExternalLogPolicy.marksExtension("diagnostic"))
    }

    @Test func batchSizeIsBounded() {
        #expect(ExternalLogPolicy.acceptsBatch(bytes: 1))
        #expect(ExternalLogPolicy.acceptsBatch(bytes: ExternalLogPolicy.maxBatchBytes))
        #expect(!ExternalLogPolicy.acceptsBatch(bytes: 0))
        #expect(!ExternalLogPolicy.acceptsBatch(bytes: ExternalLogPolicy.maxBatchBytes + 1))
    }

    @Test func pendingQueueBoundaries() {
        #expect(ExternalLogPolicy.canEnqueue(pendingBatches: 31, pendingBytes: 0, newBatchBytes: 1))
        #expect(!ExternalLogPolicy.canEnqueue(pendingBatches: 32, pendingBytes: 0, newBatchBytes: 1))
        #expect(ExternalLogPolicy.canEnqueue(pendingBatches: 0,
                                            pendingBytes: ExternalLogPolicy.maxPendingBytes - 1,
                                            newBatchBytes: 1))
        #expect(!ExternalLogPolicy.canEnqueue(pendingBatches: 0,
                                             pendingBytes: ExternalLogPolicy.maxPendingBytes,
                                             newBatchBytes: 1))
    }

    @Test func freshConnectionSubscribesAndUnsubscribes() {
        var sessions = ExternalLogSubscriptions<Int>()
        let subscribed = sessions.setSubscribed(true, id: 1)
        #expect(subscribed)
        #expect(sessions.count == 1)
        #expect(sessions.receivesExternalLogs(1))

        let unsubscribed = sessions.setSubscribed(false, id: 1)
        #expect(!unsubscribed)
        #expect(sessions.count == 0)
        #expect(!sessions.receivesExternalLogs(1))
    }

    @Test func extensionRolePersistsUntilConnectionEnds() {
        var sessions = ExternalLogSubscriptions<Int>()
        _ = sessions.setSubscribed(true, id: 2)

        sessions.markExtension(2)
        #expect(!sessions.receivesExternalLogs(2))
        #expect(sessions.count == 0)
        let resubscribed = sessions.setSubscribed(true, id: 2)
        #expect(!resubscribed)

        sessions.retainExisting { _ in true }
        #expect(!sessions.receivesExternalLogs(2))

        sessions.retainExisting { _ in false }
        let afterReconnect = sessions.setSubscribed(true, id: 2)
        #expect(afterReconnect)
    }

    @Test func disconnectedSessionsArePruned() {
        var sessions = ExternalLogSubscriptions<Int>()
        _ = sessions.setSubscribed(true, id: 1)
        _ = sessions.setSubscribed(true, id: 2)

        sessions.retainExisting { $0 == 1 }
        #expect(sessions.count == 1)
        #expect(sessions.receivesExternalLogs(1))
        #expect(!sessions.receivesExternalLogs(2))
    }

    @Test func drainDropsEntriesFromPreviousTransport() {
        var entries = [
            ExternalLogEntry(transport: "http", item: "a"),
            ExternalLogEntry(transport: "socket", item: "b"),
            ExternalLogEntry(transport: "http", item: "c"),
            ExternalLogEntry(transport: "socket", item: "d")
        ]

        let drained = ExternalLogPolicy.takeDrainable(&entries, transport: "socket", limit: 10)
        #expect(drained == ["b", "d"])
        #expect(entries.isEmpty)
    }

    @Test func drainRespectsLimitAndKeepsRemainingEntries() {
        var entries = [
            ExternalLogEntry(transport: "http", item: "a"),
            ExternalLogEntry(transport: "http", item: "b"),
            ExternalLogEntry(transport: "http", item: "c")
        ]

        let drained = ExternalLogPolicy.takeDrainable(&entries, transport: "http", limit: 2)
        #expect(drained == ["a", "b"])
        #expect(entries.map(\.item) == ["c"])
    }
}
