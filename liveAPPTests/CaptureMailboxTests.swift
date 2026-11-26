import Foundation
import Testing
@testable import liveAPP

@Suite("CaptureMailbox diagnostics")
struct CaptureMailboxTests {
    private final class Clock: @unchecked Sendable {
        var now: Double
        init(_ now: Double) { self.now = now }
    }

    @Test("summary 保留峰值與最舊等待時間")
    func summaryReportsPeakAndOldest() {
        let clock = Clock(100)
        let mailbox = CaptureMailbox<Int>(budget: 100, maxDelay: 10, clock: { clock.now })
        mailbox.offer(1, bytes: 40)
        clock.now = 103
        mailbox.offer(2, bytes: 20)
        let summary = mailbox.summary
        #expect(summary.contains("queued=2"))
        #expect(summary.contains("peakBytes=60"))
        #expect(summary.contains("oldestMs=3000.0"))
        #expect(summary.contains("peakOldestMs=3000.0"))
        #expect(summary.contains("maxDelayMs=10000.0"))
    }

    @Test("空佇列的 oldest 為 unknown，不是 0")
    func emptyQueueOldestIsUnknown() {
        let mailbox = CaptureMailbox<Int>(budget: 100)
        #expect(mailbox.summary.contains("oldestMs=unknown"))
        #expect(mailbox.oldestDelaySeconds == nil)
    }
}
