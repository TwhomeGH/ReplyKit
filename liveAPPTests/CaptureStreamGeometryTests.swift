import CoreGraphics
import Testing
@testable import liveAPP

struct CaptureStreamGeometryTests {
    @Test func fixedCanvasWinsAndRotationOnlySwapsCaptureBuffer() {
        let geometry = CaptureStreamGeometry.resolve(
            output: CGSize(width: 1280, height: 720),
            intermediate: CGSize(width: 1552, height: 1080),
            source: nil,
            rotation: .left,
            fixedCanvas: CGSize(width: 1920, height: 1080),
            fallback: CGSize(width: 1280, height: 720))

        #expect(geometry.encoderSize == CGSize(width: 1920, height: 1080))
        #expect(geometry.captureBufferSize == CGSize(width: 1080, height: 1920))
        #expect(geometry.rotatorCanvas == geometry.encoderSize)
        #expect(geometry.overlayCanvas == geometry.encoderSize)
        #expect(geometry.intermediateSize == CGSize(width: 1552, height: 1080))
        #expect(geometry.orientation == .landscape)
    }

    @Test func odIsFinalCanvasAndPortraitDoesNotSwapEncoder() {
        let geometry = CaptureStreamGeometry.resolve(
            output: CGSize(width: 1080, height: 1920),
            intermediate: nil,
            source: CGSize(width: 1920, height: 1080),
            rotation: .none,
            fixedCanvas: nil,
            fallback: CGSize(width: 1920, height: 1080))

        #expect(geometry.encoderSize == CGSize(width: 1080, height: 1920))
        #expect(geometry.captureBufferSize == CGSize(width: 1080, height: 1920))
        #expect(geometry.orientation == .portrait)
    }

    @Test func adIsFallbackWhenODIsNotAValidPair() {
        let geometry = CaptureStreamGeometry.resolve(
            output: CGSize(width: 1280, height: 0),
            intermediate: CGSize(width: 1552, height: 1080),
            source: nil,
            rotation: .none,
            fixedCanvas: nil,
            fallback: CGSize(width: 1920, height: 1080))

        #expect(geometry.encoderSize == CGSize(width: 1552, height: 1080))
    }

    @Test func nativeRotatesSourceForEncoderButKeepsCaptureOrientation() {
        let geometry = CaptureStreamGeometry.resolve(
            output: nil,
            intermediate: nil,
            source: CGSize(width: 1640, height: 2360),
            rotation: .left,
            fixedCanvas: nil,
            fallback: CGSize(width: 1920, height: 1080))

        #expect(geometry.encoderSize == CGSize(width: 2360, height: 1640))
        #expect(geometry.captureBufferSize == CGSize(width: 1640, height: 2360))
    }

    @Test func invalidSizesFallBackAndOddValuesRoundDown() {
        let geometry = CaptureStreamGeometry.resolve(
            output: CGSize(width: 1921, height: 1081),
            intermediate: nil,
            source: nil,
            rotation: .right,
            fixedCanvas: nil,
            fallback: CGSize(width: 1280, height: 720))

        #expect(geometry.encoderSize == CGSize(width: 1920, height: 1080))
        #expect(geometry.captureBufferSize == CGSize(width: 1080, height: 1920))
        #expect(geometry.orientation == .landscape)
    }

    @Test func rotateLeftFlagMapsToLeftRotation() {
        #expect(CaptureStreamRotation(rotateLeft: true) == .left)
        #expect(CaptureStreamRotation(rotateLeft: false) == .none)
    }
}
