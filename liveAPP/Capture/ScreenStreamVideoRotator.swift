#if os(iOS) && canImport(Metal)
import AVFoundation
import CoreGraphics
import CoreImage
import Metal

/// 單一 video worker 使用的 GPU 影像階段：可選左轉 90° + 疊加輸出層（時間層）。
/// 重用 context 與有限的 buffer pool，保留原始時間戳。
// Sendable 僅供移交至 worker；建立後只能由單一 video worker 呼叫 rotate。
final class ScreenStreamVideoRotator: @unchecked Sendable {
    private let context: CIContext
    private let rotateLeft: Bool
    private let overlay: ScreenOverlayComposer?
    private var pool: CVPixelBufferPool?
    private var width = 0
    private var height = 0

    init(rotateLeft: Bool = true, overlay: ScreenOverlayComposer? = nil) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RotationError.unavailable }
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        self.rotateLeft = rotateLeft
        self.overlay = overlay
    }

    /// 旋轉（可選）並疊加輸出層。池已滿時丟棄該幀，不回退成方向錯誤的畫面。
    func rotate(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
        guard let source = sample.imageBuffer else { throw RotationError.invalidSample }
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        let outWidth = rotateLeft ? sourceHeight : sourceWidth
        let outHeight = rotateLeft ? sourceWidth : sourceHeight
        let canvas = CGSize(width: outWidth, height: outHeight)
        let layer = overlay?.layer(canvas: canvas)
        // 無旋轉且無疊加 → 原樣返回，省一次 GPU pass。
        if !rotateLeft, layer == nil { return sample }

        if pool == nil || width != outWidth || height != outHeight {
            pool = nil
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: outWidth, kCVPixelBufferHeightKey as String: outHeight,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            try check(CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool))
            width = outWidth; height = outHeight
        }
        guard let pool else { throw RotationError.invalidSample }
        var destination: CVPixelBuffer?
        try check(CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary, &destination))
        guard let destination else { throw RotationError.invalidSample }

        var image = CIImage(cvPixelBuffer: source)
        if rotateLeft { image = image.oriented(.left) }
        context.render(image, to: destination)

        if let layer {
            draw(layer, into: destination)
        }

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

    /// 以左上原點 CTM 把疊加圖畫進 BGRA 緩衝（與 `OverlayAnchor` 座標一致）。
    private func draw(_ layer: (image: CGImage, origin: CGPoint, size: CGSize), into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let ctx = CGContext(
            data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        // CGContext 原點在左下；OverlayAnchor.origin 是左上座標，把 y 換算到左下即可，
        // 不要再翻轉 CTM（翻 CTM 會連同 draw 的圖片一起上下顛倒）。
        let y = CGFloat(h) - layer.origin.y - layer.size.height
        ctx.draw(layer.image, in: CGRect(x: layer.origin.x, y: y, width: layer.size.width, height: layer.size.height))
    }

    private func check(_ status: Int32) throws {
        if status != 0 { throw RotationError.status(status) }
    }
    private enum RotationError: Error { case unavailable, invalidSample, status(Int32) }
}
#endif
