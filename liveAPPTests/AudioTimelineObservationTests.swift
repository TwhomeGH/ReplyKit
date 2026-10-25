import Testing
@testable import liveAPP

struct AudioTimelineObservationTests {
    @Test func continuousSamplesAndGapAreDistinguished() {
        var value = AudioTimelineObservation()
        value.record(pts: 100, frames: 480, rate: 48000, signature: "48k")
        value.record(pts: 100.01, frames: 480, rate: 48000, signature: "48k")
        #expect(value.summary.contains("spanMinusContentSeconds=0.000000"))
        value.record(pts: 101, frames: 480, rate: 48000, signature: "48k")
        #expect(value.summary.contains("spanMinusContentSeconds=0.980000"))
        #expect(value.summary.contains("discontinuities=1"))
        value.record(pts: 102, frames: 441, rate: 44100, signature: "44k")
        #expect(value.generation == 2)
        #expect(value.summary.contains("frames=441"))
        #expect(value.summary.contains("discontinuities=0"))
    }

    @Test func invalidTimeDoesNotInventOrigin() {
        var value = AudioTimelineObservation()
        value.record(pts: .nan, frames: 480, rate: 48000, signature: "48k")
        #expect(value.generation == 0)
        #expect(value.summary.contains("firstPTS=unknown"))
        #expect(value.summary.contains("invalid=1"))
    }
}
