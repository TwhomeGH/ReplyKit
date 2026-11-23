import Foundation
import Testing
@testable import liveAPP

struct CaptureCallbackDiagnosticsTests {
    @Test func separatesRejectedFramesAndTimestampObservations() {
        let probe = CaptureCallbackDiagnostics()
        #expect(probe.summary(now: 100).contains("idleSeconds=unknown"))
        probe.record(track: .video, outcome: .nonComplete, state: "idle", arrival: 100, pts: 99)
        probe.record(track: .video, outcome: .offered, state: "complete", arrival: 103, pts: 102)
        probe.record(track: .video, outcome: .invalid, state: nil, arrival: 104, pts: .nan)
        let summary = probe.summary(now: 106)
        #expect(summary.contains("video{callbacks=3"))
        #expect(summary.contains("nonComplete=1"))
        #expect(summary.contains("offered=1"))
        #expect(summary.contains("invalidPTS=1"))
        #expect(summary.contains("maxCallbackGapSeconds=3.000000"))
        #expect(summary.contains("idleSeconds=2.000000"))
        #expect(summary.contains("hostMinusPTSSeconds=unknown"))
    }

    @Test func tracksRegressionsWithoutClampingSignedClockDifference() {
        let probe = CaptureCallbackDiagnostics()
        probe.record(track: .audio, outcome: .offered, state: nil, arrival: 10, pts: 12)
        probe.record(track: .audio, outcome: .offered, state: nil, arrival: 11, pts: 11)
        let summary = probe.summary(now: 11)
        #expect(summary.contains("regress=1"))
        #expect(summary.contains("minHostMinusPTSSeconds=-2.000000"))
        #expect(summary.contains("video{callbacks=0"))
    }

    @Test func bucketsLongCallbackGaps() {
        let probe = CaptureCallbackDiagnostics()
        probe.record(track: .video, outcome: .offered, state: nil, arrival: 0, pts: 0)
        probe.record(track: .video, outcome: .offered, state: nil, arrival: 0.6, pts: 0.6)
        probe.record(track: .video, outcome: .offered, state: nil, arrival: 3.0, pts: 3.0)
        probe.record(track: .video, outcome: .offered, state: nil, arrival: 9.0, pts: 9.0)
        let summary = probe.summary(now: 9)
        #expect(summary.contains("lastGapSeconds=6.000000"))
        #expect(summary.contains("gapsOver500ms=3"))
        #expect(summary.contains("gapsOver2s=2"))
        #expect(summary.contains("gapsOver5s=1"))
    }
}
