import Testing
@testable import liveAPP

struct PIPAdAnimationTests {
    @Test func entryHoldAndExitHaveContinuousVisibility() {
        #expect(PIPAdAnimation.visibility(elapsed: 0, duration: 10) == 0)
        #expect(PIPAdAnimation.visibility(elapsed: 0.175, duration: 10) == 0.5)
        #expect(PIPAdAnimation.visibility(elapsed: 5, duration: 10) == 1)
        #expect(PIPAdAnimation.visibility(elapsed: 10, duration: 10) == 0)
        #expect(PIPAdAnimation.visibility(elapsed: 11, duration: 10) == 0)
    }

    @Test func lowCadenceWakesBeforeFadeOut() {
        let interval = PIPAdAnimation.nextInterval(elapsed: 9.5, duration: 10, proposed: 0.5)
        #expect(abs(interval - 0.15) < 0.000001)
        #expect(PIPAdAnimation.isTransitioning(elapsed: 9.66, duration: 10))
    }

    @Test func shortAndInvalidDurationsStayBounded() {
        #expect(PIPAdAnimation.visibility(elapsed: 0.1, duration: 0.2) == 1)
        #expect(PIPAdAnimation.visibility(elapsed: 0, duration: 0) == 0)
        #expect(!PIPAdAnimation.isTransitioning(elapsed: .nan, duration: 10))
    }
}
