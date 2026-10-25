import Testing
@testable import liveAPP

struct ProcessingInFlightTrackerTests {
    @Test func overlappingCommandsCountUnionAcrossSamples() {
        let tracker = ProcessingInFlightTracker()
        #expect(tracker.sample(at: 0).load == nil)
        tracker.begin(at: 1, preparationMs: 2, angle: 90, width: 1920, height: 1080, overlay: false)
        tracker.begin(at: 2, preparationMs: 3, angle: 90, width: 1920, height: 1080, overlay: false)
        tracker.end(at: 3, elapsedMs: 2000, success: true)
        #expect(tracker.sample(at: 5).load?.busyPercent == 80)
        tracker.end(at: 6, elapsedMs: 4000, success: false)
        let second = tracker.sample(at: 10)
        #expect(second.load?.busyPercent == 20)
        #expect(second.summary.contains("failed=1 inFlight=0"))
        #expect(second.summary.contains("overlayEncoded=false"))
        #expect(tracker.sample(at: 15).load?.busyPercent == 0)
    }
}
