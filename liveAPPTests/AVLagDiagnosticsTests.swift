import Foundation
import Testing
@testable import liveAPP

struct AVLagDiagnosticsTests {
    @Test func recordsVideoAudioAndStageAges() {
        let diagnostics = AVLagDiagnostics()
        diagnostics.recordVideo(arrival: 100.00, pts: 99.50, at: 100.00,
                                queue: "queued=1", queueOldestAge: 0.25)
        diagnostics.recordVideoProcessed(arrival: 100.00, pts: 99.50, at: 100.05,
                                         queue: "queued=0", queueOldestAge: nil)
        diagnostics.recordAudio(arrival: 100.10, pts: 99.40, at: 100.10, isMic: false)

        let snapshot = diagnostics.snapshot(session: "s", now: 100.20)
        #expect(snapshot != nil)
        #expect(snapshot?.videoContentAge == 0.50)
        #expect(abs((snapshot?.audioContentAge ?? 0) - 0.70) < 0.0001)
        #expect(snapshot?.videoQueueAge == 0.00)
        #expect(snapshot?.videoQueueOldestAge == 0.25)
        #expect(abs((snapshot?.videoProcessAge ?? 0) - 0.05) < 0.0001)
        #expect(abs((snapshot?.videoSourceAge ?? 0) - 0.55) < 0.0001)
        #expect(abs((snapshot?.videoIdleAge ?? 0) - 0.15) < 0.0001)
        #expect(abs((snapshot?.sourcePTSDelta ?? 0) - 0.10) < 0.0001)
        #expect(snapshot?.videoFrames == 1)
        #expect(snapshot?.audioFrames == 1)
    }

    @Test func reportsOneStepJumpThenConsumesIt() {
        let diagnostics = AVLagDiagnostics()
        diagnostics.recordVideo(arrival: 10, pts: 9.5, at: 10, queue: "q", queueOldestAge: nil)
        #expect(diagnostics.snapshot(session: "s", now: 10)?.contentAgeJump == nil)

        diagnostics.recordVideo(arrival: 20, pts: 18.4, at: 20, queue: "q", queueOldestAge: nil)
        let jumped = diagnostics.snapshot(session: "s", now: 20)
        #expect(abs((jumped?.contentAgeJump ?? 0) - 1.1) < 0.0001)
        #expect(diagnostics.snapshot(session: "s", now: 21)?.contentAgeJump == nil)
    }

    @Test func reportsSourceDeltaDriftAndSyncState() {
        let diagnostics = AVLagDiagnostics()
        diagnostics.recordVideo(arrival: 100, pts: 100, at: 100, queue: "q", queueOldestAge: nil)
        diagnostics.recordAudio(arrival: 100, pts: 99.97, at: 100, isMic: false)
        let baseline = diagnostics.snapshot(session: "s", now: 100)
        #expect(abs((baseline?.sourcePTSDeltaDrift ?? 1) - 0) < 0.0001)
        #expect(baseline?.avSyncState == "stable")

        diagnostics.recordVideo(arrival: 160, pts: 160, at: 160, queue: "q", queueOldestAge: nil)
        diagnostics.recordAudio(arrival: 160, pts: 159.77, at: 160, isMic: false)
        let drifted = diagnostics.snapshot(session: "s", now: 160)
        #expect(abs((drifted?.sourcePTSDeltaDrift ?? 0) - 0.2) < 0.0001)
        #expect(abs((drifted?.sourcePTSDeltaPerMinute ?? 0) - 0.2) < 0.0001)
        #expect(abs((drifted?.avClockDrift ?? 0) - 0.23) < 0.0001)
        #expect(drifted?.avSyncState == "drifting")
    }

    @Test func noVideoMeansUnknownInsteadOfZero() {
        let diagnostics = AVLagDiagnostics()
        diagnostics.recordAudio(arrival: 1, pts: 1, at: 1, isMic: false)
        #expect(diagnostics.snapshot(session: "s", now: 2) == nil)
    }

    @Test func microphoneDoesNotOverwriteSystemAudio() {
        let diagnostics = AVLagDiagnostics()
        diagnostics.recordVideo(arrival: 10, pts: 9, at: 10, queue: "q", queueOldestAge: nil)
        diagnostics.recordAudio(arrival: 10, pts: 9.5, at: 10, isMic: false)
        diagnostics.recordAudio(arrival: 11, pts: 90, at: 11, isMic: true)
        let snapshot = diagnostics.snapshot(session: "s", now: 12)
        #expect(snapshot?.audioPTS == 9.5)
        #expect(snapshot?.audioFrames == 1)
    }
}
