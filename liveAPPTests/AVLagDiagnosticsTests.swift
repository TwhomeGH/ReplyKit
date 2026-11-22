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
        #expect(abs((snapshot?.videoIdleAge ?? 0) - 0.20) < 0.0001)
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
        #expect(baseline?.avSyncState == "unpairedObservation")

        diagnostics.recordVideo(arrival: 160, pts: 160, at: 160, queue: "q", queueOldestAge: nil)
        diagnostics.recordAudio(arrival: 160, pts: 159.77, at: 160, isMic: false)
        let drifted = diagnostics.snapshot(session: "s", now: 160)
        #expect(abs((drifted?.sourcePTSDeltaDrift ?? 0) - 0.2) < 0.0001)
        #expect(abs((drifted?.sourcePTSDeltaPerMinute ?? 0) - 0.2) < 0.0001)
        #expect(abs((drifted?.avClockDrift ?? 0) - 0.23) < 0.0001)
        #expect(drifted?.avSyncState == "unpairedObservation")
    }

    @Test func staleSamplesDoNotClaimSynchronization() {
        let diagnostics = AVLagDiagnostics()
        diagnostics.recordVideo(arrival: 100, pts: 100, at: 100, queue: "q", queueOldestAge: nil)
        diagnostics.recordAudio(arrival: 101, pts: 101, at: 101, isMic: false)
        let sample = diagnostics.snapshot(session: "s", now: 101)
        #expect(sample?.avSyncState == "stale")
        #expect(sample?.contentSynchronization == "notMeasured")
        #expect(sample?.audioIdleAge == 0)
    }

    @Test("來源過期不更新基準，恢復後重新觀測")
    func staleBaselineResetsOnRecovery() {
        let diagnostics = AVLagDiagnostics()
        diagnostics.recordVideo(arrival: 100, pts: 100, at: 100, queue: "q", queueOldestAge: nil)
        diagnostics.recordAudio(arrival: 100, pts: 99, at: 100, isMic: false)
        _ = diagnostics.snapshot(session: "s", now: 100)
        let stale = diagnostics.snapshot(session: "s", now: 101)
        #expect(stale?.sourcePTSDeltaDrift == nil)
        #expect(stale?.sourcePTSDeltaPerMinute == nil)
        diagnostics.recordVideo(arrival: 102, pts: 102, at: 102, queue: "q", queueOldestAge: nil)
        diagnostics.recordAudio(arrival: 102, pts: 102, at: 102, isMic: false)
        #expect(diagnostics.snapshot(session: "s", now: 102)?.sourcePTSDeltaDrift == 0)
    }

    @Test("加工完成不刷新來源回呼時間，日誌保留兩軌新鮮度")
    func workerProgressDoesNotRefreshSource() {
        let diagnostics = AVLagDiagnostics()
        diagnostics.recordVideo(arrival: 100, pts: 100, at: 101, queue: "q", queueOldestAge: nil)
        diagnostics.recordVideoProcessed(arrival: 100, pts: 100, at: 102, queue: "q", queueOldestAge: nil)
        diagnostics.recordAudio(arrival: 100, pts: 100, at: 102, isMic: false)
        let sample = diagnostics.snapshot(session: "s", now: 102)
        #expect(sample?.videoIdleAge == 2)
        #expect(sample?.audioIdleAge == 2)
        #expect(sample?.videoWorkerIdleAge == 0)
        #expect(sample?.audioWorkerIdleAge == 0)
        #expect(sample?.avSyncState == "stale")
        #expect(sample?.logLine.contains("audioIdleAge=2.000000") == true)
    }

    @Test func exportHasTaipeiOffsetAndMilliseconds() throws {
        let date = Date(timeIntervalSince1970: 0.125)
        let document = AVLagReportDocument(session: "s", startedAt: date, segmentIndex: 0,
            segmentStartedAt: date, complete: false, sessionComplete: false,
            truncatedBefore: false, sampleCount: 0, samples: [])
        let data = try document.encoded()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["startedAt"] as? String == "1970-01-01T08:00:00.125+08:00")
        #expect(object["timeZone"] as? String == "Asia/Taipei")
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
