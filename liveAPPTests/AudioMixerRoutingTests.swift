import HaishinKit
import Testing
@testable import liveAPP

struct AudioMixerRoutingTests {
    @Test func microphoneBecomesMainClockWhenEnabled() {
        let settings = CaptureMediaPipeline.audioSettings(
            from: AudioMixerSettings(), microphone: true)

        #expect(settings.mainTrack == 1)
        #expect(settings.outputFormatTrack == 0)
        #expect(settings.tracks[0] != nil)
        #expect(settings.tracks[1] != nil)
    }

    @Test func appTrackRemainsMainClockWithoutMicrophone() {
        let settings = CaptureMediaPipeline.audioSettings(
            from: AudioMixerSettings(), microphone: false)

        #expect(settings.mainTrack == 0)
        #expect(settings.outputFormatTrack == 0)
        #expect(settings.tracks[0] != nil)
        #expect(settings.tracks[1] == nil)
    }
}
