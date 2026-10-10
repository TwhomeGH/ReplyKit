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
    /// 固定輸出畫布；nil = 跟隨來源尺寸（native）。
    private let canvas: CGSize?
    /// 來源填入畫布的方式：true = 裁切填滿，false = 內縮含黑邊。
    private let fills: Bool
    private var pool: CVPixelBufferPool?
    private var width = 0
    private var height = 0

    init(rotateLeft: Bool = true, overlay: ScreenOverlayComposer? = nil,
         canvas: CGSize? = nil, fills: Bool = false) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RotationError.unavailable }
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        self.rotateLeft = rotateLeft
        self.overlay = overlay
        self.canvas = canvas
        self.fills = fills
    }

    /// 旋轉（可選）並疊加輸出層。池已滿時丟棄該幀，不回退成方向錯誤的畫面。
    func rotate(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
        guard let source = sample.imageBuffer else { throw RotationError.invalidSample }
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        // 旋轉後的來源尺寸（跟隨來源時即為輸出尺寸）。
        let rotatedWidth = rotateLeft ? sourceHeight : sourceWidth
        let rotatedHeight = rotateLeft ? sourceWidth : sourceHeight
        // 輸出畫布：固定政策用固定尺寸，native（canvas == nil）用來源尺寸。
        let outWidth = canvas.map { Int($0.width) } ?? rotatedWidth
        let outHeight = canvas.map { Int($0.height) } ?? rotatedHeight
        // 疊加層一律以「輸出畫布」為座標系（錨點即畫布四角）。
        let layer = overlay?.layer(canvas: CGSize(width: outWidth, height: outHeight))
        let needsScale = outWidth != rotatedWidth || outHeight != rotatedHeight
        // 無旋轉、無縮放、無疊加 → 原樣返回，省一次 GPU pass。
        if !rotateLeft, !needsScale, layer == nil { return sample }

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
        // `CIContext.render(_:to:)` 會把 image 的 extent 映射到整個緩衝，因此必須把
        // 結果「裁到畫布 + 疊在黑底上」，讓 extent 恰好等於畫布尺寸，才不會被拉伸。
        let canvasRect = CGRect(x: 0, y: 0, width: outWidth, height: outHeight)
        if needsScale {
            let extent = image.extent
            // 內縮（min）留黑邊、填滿（max）裁切，再置中。
            let scale = fills
                ? max(CGFloat(outWidth) / extent.width, CGFloat(outHeight) / extent.height)
                : min(CGFloat(outWidth) / extent.width, CGFloat(outHeight) / extent.height)
            let dx = (CGFloat(outWidth) - extent.width * scale) / 2 - extent.origin.x * scale
            let dy = (CGFloat(outHeight) - extent.height * scale) / 2 - extent.origin.y * scale
            image = image
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: dx, y: dy))
                .cropped(to: canvasRect)
        }
        image = image.composited(over: CIImage(color: .black).cropped(to: canvasRect))
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
