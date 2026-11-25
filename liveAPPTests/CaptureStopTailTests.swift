import Foundation
import Testing
@testable import liveAPP

@Suite("CaptureStopTail")
struct CaptureStopTailTests {
    @Test("影片先停、音訊在 1 秒內結束")
    func audioEndsWithinOneSecond() throws {
        let tail = CaptureStopTail(videoPTS: 10, audioPTS: 10.2, micPTS: nil)
        let value = try #require(tail.audioTailSeconds)
        #expect(abs(value - 0.2) < 1e-9)
        #expect(tail.verdict == .withinOneSecond)
        #expect(tail.logLine.contains("verdict=withinOneSecond"))
    }

    @Test("音訊比影片早超過 1 秒停止")
    func audioStoppedEarly() {
        let tail = CaptureStopTail(videoPTS: 10, audioPTS: 6, micPTS: nil)
        #expect(tail.audioTailSeconds == -4)
        #expect(tail.verdict == .audioStoppedEarly)
    }

    @Test("音訊比影片晚超過 1 秒停止")
    func audioContinuedAfterVideo() {
        let tail = CaptureStopTail(videoPTS: 10, audioPTS: 12, micPTS: 11)
        #expect(tail.audioTailSeconds == 2)
        #expect(tail.verdict == .audioContinuedAfterVideo)
    }

    @Test("缺少時間軸時不假裝正常")
    func missingTimelineIsUnknown() {
        let tail = CaptureStopTail(videoPTS: nil, audioPTS: 10, micPTS: nil)
        #expect(tail.audioTailSeconds == nil)
        #expect(tail.verdict == .unknown)
        #expect(tail.logLine.contains("videoLastPTS=unknown"))
    }

    @Test("callback 診斷保留最後有效 PTS")
    func diagnosticsKeepsLastValidPTS() {
        let diagnostics = CaptureCallbackDiagnostics()
        diagnostics.record(track: .video, outcome: .offered, state: "complete",
                          arrival: 100, pts: 99.5)
        diagnostics.record(track: .video, outcome: .offered, state: "complete",
                          arrival: 100.1, pts: 99.6)
        diagnostics.record(track: .video, outcome: .invalid, state: nil,
                          arrival: 100.2, pts: .nan)
        #expect(diagnostics.lastPTS(track: .video) == 99.6)
        #expect(diagnostics.lastPTS(track: .audio) == nil)
    }
}
