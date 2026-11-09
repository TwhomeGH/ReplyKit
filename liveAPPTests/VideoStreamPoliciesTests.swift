import Testing
@testable import liveAPP

struct VideoStreamPoliciesTests {
    @Test func bufferCountZeroAndNegativeAreAutomatic() {
        #expect(VideoBufferPolicy.resolve(rawValue: -1) == .automatic)
        #expect(VideoBufferPolicy.resolve(rawValue: 0) == .automatic)
        #expect(VideoBufferPolicy.resolve(rawValue: -20) == .automatic)
        #expect(VideoBufferPolicy.resolve(rawValue: 4) == .frames(4))
        #expect(VideoBufferPolicy.resolve(rawValue: 500) == .frames(100))
    }

    @Test func bufferCountMapsToEncoderAndQueuePolicies() {
        let automatic = VideoBufferPolicy.automatic
        #expect(automatic.maxFrameDelayCount == -1)
        #expect(automatic.inputBufferCounts == nil)
        #expect(automatic.rawValue == -1)

        let fixed = VideoBufferPolicy.frames(6)
        #expect(fixed.maxFrameDelayCount == 6)
        #expect(fixed.inputBufferCounts == 6)
        #expect(fixed.rawValue == 6)
    }

    @Test func keyFrameZeroAndNegativeAreAutomatic() {
        #expect(KeyFrameIntervalPolicy.resolve(rawValue: 0) == .automatic)
        #expect(KeyFrameIntervalPolicy.resolve(rawValue: -5) == .automatic)
        #expect(KeyFrameIntervalPolicy.resolve(rawValue: 2) == .seconds(2))
        #expect(KeyFrameIntervalPolicy.resolve(rawValue: 500) == .seconds(60))
        #expect(KeyFrameIntervalPolicy.automatic.duration == 0)
        #expect(KeyFrameIntervalPolicy.seconds(3).duration == 3)
    }
}
