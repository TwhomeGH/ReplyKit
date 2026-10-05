#if os(iOS) && canImport(Metal)
import AVFoundation
import CoreImage
import Metal

/// 單一 video worker 使用的 GPU 左轉器。重用 context 與有限的 buffer pool，保留原始時間戳。
/// 只處理推流；原生 SCRecordingOutput 的方向仍由錄影設定控制。
// Sendable 僅供移交至 worker；建立後只能由單一 video worker 呼叫 rotate。
final class ScreenStreamVideoRotator: @unchecked Sendable {
    private let context: CIContext
    private var pool: CVPixelBufferPool?
    private var width = 0
    private var height = 0

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RotationError.unavailable }
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }

    /// 將像素逆時針旋轉 90 度。池已滿時丟棄該幀，不回退成方向錯誤的畫面。
    func rotate(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
        guard let source = sample.imageBuffer else { throw RotationError.invalidSample }
        let w = CVPixelBufferGetHeight(source), h = CVPixelBufferGetWidth(source)
        if pool == nil || width != w || height != h {
            pool = nil
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            try check(CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool))
            width = w; height = h
        }
        guard let pool else { throw RotationError.invalidSample }
        var destination: CVPixelBuffer?
        try check(CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary, &destination))
        guard let destination else { throw RotationError.invalidSample }
        let image = CIImage(cvPixelBuffer: source).oriented(.left)
        context.render(image, to: destination)
        var description: CMVideoFormatDescription?
        try check(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: destination, formatDescriptionOut: &description))
        guard let description else { throw RotationError.invalidSample }
        var timing = CMSampleTimingInfo(duration: sample.duration,
            presentationTimeStamp: sample.presentationTimeStamp, decodeTimeStamp: sample.decodeTimeStamp)
        var result: CMSampleBuffer?
        try check(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: destination, formatDescription: description, sampleTiming: &timing, sampleBufferOut: &result))
        guard let result else { throw RotationError.invalidSample }
        return result
    }

    private func check(_ status: Int32) throws {
        if status != 0 { throw RotationError.status(status) }
    }
    private enum RotationError: Error { case unavailable, invalidSample, status(Int32) }
}
#endif
