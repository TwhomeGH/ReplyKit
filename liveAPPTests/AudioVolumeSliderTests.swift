import Foundation
import Testing
@testable import liveAPP

struct AudioVolumeSliderTests {
    @Test func midpointIsMinus20dB() {
        let volume = percentageToVolume(0.5)
        #expect(abs(volume - 0.1) < 0.0001)
    }

    @Test func minus38Point9DbIsNearTheLowEnd() {
        let volume = pow(10.0, -38.9 / 20.0)
        #expect(volumeToPercentage(volume) < 0.05)
    }

    @Test func endpointsRemainMuteAndUnity() {
        #expect(percentageToVolume(0) == 0)
        #expect(percentageToVolume(1) == 1)
        #expect(volumeToPercentage(0) == 0)
        #expect(volumeToPercentage(1) == 1)
    }
}
