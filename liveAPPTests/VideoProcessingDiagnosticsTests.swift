import Testing
@testable import liveAPP

struct VideoProcessingDiagnosticsTests {
    @Test func busyIntervalsIncludeInFlightWorkWithoutDoubleCounting() {
        let tracker = VideoProcessingDiagnostics()
        #expect(tracker.sampleLoad(at: 0) == nil)
        tracker.begin(at: 2)
        let first = tracker.sampleLoad(at: 5)
        #expect(first?.busySeconds == 3)
        #expect(first?.busyPercent == 60)
        #expect(first?.inFlight == true)
        tracker.record(inputPTS: 1, outputPTS: 1, elapsed: 5, bypass: false,
                       configuration: VideoProcessingFrameInfo(), error: nil, completedAt: 7)
        let second = tracker.sampleLoad(at: 10)
        #expect(second?.busySeconds == 2)
        #expect(second?.busyPercent == 40)
        #expect(second?.inFlight == false)
        #expect(tracker.sampleLoad(at: 10) == nil)
        #expect(tracker.sampleLoad(at: 15)?.busyPercent == 0)
    }

    @Test func budgetScalesWithResolution() {
        #expect(VideoProcessingBudget.limit(width: 1920, height: 1080) == 6)
        #expect(VideoProcessingBudget.limit(width: 3840, height: 2160) == 1)
        #expect(VideoProcessingBudget.limit(width: 8192, height: 8192) == nil)
        #expect(VideoProcessingBudget.limit(width: 0, height: 1080) == nil)
    }

    @Test func overlayDegradationStillCountsAsSuccessfulVideo() {
        let tracker = VideoProcessingDiagnostics()
        tracker.record(inputPTS: 1, outputPTS: 1, elapsed: 0.01, bypass: true,
                       configuration: VideoProcessingFrameInfo(overlayDegraded: true), error: nil)
        #expect(tracker.summary.contains("bypassed=1 failed=0"))
        #expect(tracker.summary.contains("overlayDegraded=1"))
    }

    @Test func resultsAndSameFrameTimesRemainDistinct() {
        let tracker = VideoProcessingDiagnostics()
        tracker.record(inputPTS: 10, outputPTS: 10, elapsed: 0.01,
                       bypass: false, configuration: VideoProcessingFrameInfo(overlay: true), error: nil)
        tracker.record(inputPTS: 11, outputPTS: 11, elapsed: 0.001,
                       bypass: true, configuration: VideoProcessingFrameInfo(), error: nil)
        tracker.record(inputPTS: 12, outputPTS: nil, elapsed: 0.02,
                       bypass: false, configuration: VideoProcessingFrameInfo(overlay: true), error: "testFailure")
        let summary = tracker.summary
        #expect(summary.contains("attempts=3 processed=1 bypassed=1 failed=1"))
        #expect(summary.contains("maxMs=20.000000"))
        #expect(summary.contains("inputPTS=12.000000 outputPTS=unknown"))
        #expect(summary.contains("lastError=testFailure"))
    }
}
