import Testing
@testable import liveAPP

struct CaptureSendProgressTests {
    @Test func stalledQueueRecoversAndReconnectResetsBaseline() {
        var tracker = CaptureSendProgress()
        _ = tracker.sample(generation: 1, completed: 100, queued: 50, failed: 0, now: 0)
        let stalled = tracker.sample(generation: 1, completed: 100, queued: 50, failed: 0, now: 11)
        #expect(stalled.changed && stalled.text.contains("state=localSendStalled"))
        let recovered = tracker.sample(generation: 1, completed: 150, queued: 0, failed: 0, now: 12)
        #expect(recovered.changed && recovered.text.contains("state=queueEmpty"))
        let reset = tracker.sample(generation: 2, completed: 0, queued: 50, failed: 0, now: 100)
        #expect(reset.text.contains("baselineReset=true"))
        #expect(reset.text.contains("state=pending"))
    }

    @Test func emptyQueueIsNotReportedAsStalled() {
        var tracker = CaptureSendProgress()
        _ = tracker.sample(generation: 1, completed: 0, queued: 0, failed: 0, now: 0)
        let result = tracker.sample(generation: 1, completed: 0, queued: 0, failed: 0, now: 120)
        #expect(result.text.contains("state=queueEmpty"))
    }
}
