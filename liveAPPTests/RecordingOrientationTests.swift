import Foundation
import Testing
@testable import liveAPP
#if os(iOS)
import CoreGraphics
#endif

struct RecordingOrientationTests {
    @Test func repeatedFramesOnlyKeepDirectionChanges() {
        let timeline = RecordingOrientationTimeline()
        for i in 0..<600 { timeline.observe(seconds: 100 + Double(i) / 60, orientation: 8) }
        timeline.observe(seconds: 110, orientation: 1)
        let result = timeline.snapshot()
        #expect(result.reliable)
        #expect(result.events == [RecordingOrientationEvent(seconds: 0, orientation: 8), RecordingOrientationEvent(seconds: 10, orientation: 1)])
    }
    @Test func unknownDirectionNeverDefaultsToAForcedRotation() {
        let timeline = RecordingOrientationTimeline()
        timeline.observe(seconds: 0, orientation: nil)
        timeline.observe(seconds: 1, orientation: 9)
        #expect(!timeline.snapshot().reliable)
        #expect(timeline.snapshot().missing == 2)
        timeline.observe(seconds: 2, orientation: 6)
        #expect(timeline.snapshot().events.first?.seconds == 0)
        #expect(timeline.snapshot().events.first?.orientation == 6)
    }
    @Test func timestampRegressionAndOverflowPreventIncorrectCorrection() {
        let reversed = RecordingOrientationTimeline()
        reversed.observe(seconds: 10, orientation: 8)
        reversed.observe(seconds: 9, orientation: 6)
        #expect(!reversed.snapshot().reliable)
        let overflow = RecordingOrientationTimeline()
        for i in 0..<5000 { overflow.observe(seconds: Double(i), orientation: i % 2 == 0 ? 1 : 8) }
        #expect(!overflow.snapshot().reliable)
        #expect(overflow.snapshot().events.count == 4096)
    }
    @Test func sameTimestampUsesTheLatestDirection() {
        let timeline = RecordingOrientationTimeline()
        timeline.observe(seconds: 10, orientation: 1)
        timeline.observe(seconds: 10, orientation: 8)
        #expect(timeline.snapshot().events == [RecordingOrientationEvent(seconds: 0, orientation: 8)])
    }
    @Test func automaticUsesInverseQuarterTurnsAndPreservesOtherExifValues() {
        #expect(RecordingOrientationPolicy.automatic.outputOrientation(for: 6) == 8)
        #expect(RecordingOrientationPolicy.automatic.outputOrientation(for: 8) == 6)
        for value in [1, 2, 3, 4, 5, 7] {
            #expect(RecordingOrientationPolicy.automatic.outputOrientation(for: value) == value)
        }
    }
    @Test func manualDirectionsIgnoreSourceMetadata() {
        for value in 1...8 {
            #expect(RecordingOrientationPolicy.none.outputOrientation(for: value) == 1)
            #expect(RecordingOrientationPolicy.left.outputOrientation(for: value) == 8)
            #expect(RecordingOrientationPolicy.right.outputOrientation(for: value) == 6)
            #expect(RecordingOrientationPolicy.halfTurn.outputOrientation(for: value) == 3)
        }
    }
    #if os(iOS)
    @Test func allExifTransformsKeepPixelsInsidePositiveOutputBounds() {
        let size = CGSize(width: 1920, height: 1080)
        for exif in 1...8 {
            let transform = RecordingOrientationCorrector.transform(exif, size: size)
            let bounds = CGRect(origin: .zero, size: size).applying(transform)
            #expect(bounds.minX == 0 && bounds.minY == 0)
            #expect(bounds.width == (exif >= 5 ? 1080 : 1920))
            #expect(bounds.height == (exif >= 5 ? 1920 : 1080))
        }
        let left = RecordingOrientationCorrector.transform(8, size: size)
        #expect(CGPoint(x: 1920, y: 0).applying(left) == .zero)
        #expect(CGPoint(x: 0, y: 0).applying(left) == CGPoint(x: 0, y: 1920))
    }
    #endif
}
