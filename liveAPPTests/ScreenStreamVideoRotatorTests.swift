#if os(iOS) && canImport(Metal)
import AVFoundation
import Metal
import Testing
@testable import liveAPP

struct ScreenStreamVideoRotatorTests {
    /// 以六個色塊檢查左轉而非右轉；同時驗證 PTS／duration 不因像素轉換改變。
    @Test func rotatesPixelsLeftAndPreservesTiming() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        var source: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 2, 3, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &source) == kCVReturnSuccess)
        let pixels = try #require(source)
        // BGRA：紅、綠 / 藍、白 / 黑、黃。左轉應為：綠、白、黃 / 紅、藍、黑。
        let colors: [[UInt8]] = [[0,0,255,255], [0,255,0,255], [255,0,0,255],
                                  [255,255,255,255], [0,0,0,255], [0,255,255,255]]
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for row in 0..<3 {
            for col in 0..<2 {
                for channel in 0..<4 { base[row * stride + col * 4 + channel] = colors[row * 2 + col][channel] }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels,
            formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: 1234, timescale: 60), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels,
            formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        let rotated = try ScreenStreamVideoRotator().rotate(#require(sample))
        #expect(rotated.presentationTimeStamp == timing.presentationTimeStamp)
        #expect(rotated.duration == timing.duration)
        let output = try #require(rotated.imageBuffer)
        #expect(CVPixelBufferGetWidth(output) == 3)
        #expect(CVPixelBufferGetHeight(output) == 2)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let data = try #require(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(to: UInt8.self)
        let outputStride = CVPixelBufferGetBytesPerRow(output)
        let expected = [1, 3, 5, 0, 2, 4]
        for row in 0..<2 {
            for col in 0..<3 {
                for channel in 0..<3 {
                    #expect(abs(Int(data[row * outputStride + col * 4 + channel]) - Int(colors[expected[row * 3 + col]][channel])) <= 3)
                }
            }
        }
    }
}
#endif
