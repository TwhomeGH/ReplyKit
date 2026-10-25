#if os(iOS) && canImport(Metal)
import AVFoundation
import CoreGraphics
import CoreImage
import Metal

/// 單一 video worker 使用的 GPU 影像階段：可選左轉 90° + 疊加輸出層（時間層）。
/// 重用 context 與有限的 buffer pool，保留原始時間戳。
// Sendable 僅供移交至 worker；建立後只能由單一 video worker 呼叫 rotate。
final class ScreenStreamVideoRotator: @unchecked Sendable {
    let diagnostics = VideoProcessingDiagnostics()
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
        let start = ProcessInfo.processInfo.systemUptime
        diagnostics.begin(at: start)
        var bypass = false
        var configuration = VideoProcessingFrameInfo(rotateLeft: rotateLeft, fills: fills)
        do {
            let result = try process(sample, bypass: &bypass, configuration: &configuration)
            diagnostics.record(inputPTS: sample.presentationTimeStamp.seconds,
                outputPTS: result.presentationTimeStamp.seconds,
                elapsed: ProcessInfo.processInfo.systemUptime - start,
                bypass: bypass, configuration: configuration, error: nil)
            return result
        } catch {
            diagnostics.record(inputPTS: sample.presentationTimeStamp.seconds, outputPTS: nil,
                elapsed: ProcessInfo.processInfo.systemUptime - start,
                bypass: false, configuration: configuration, error: String(describing: error))
            throw error
        }
    }

    /// 單 worker 執行實際加工；只回傳完成的樣本，失敗交由統一統計記錄。
    private func process(_ sample: CMSampleBuffer, bypass: inout Bool,
                         configuration: inout VideoProcessingFrameInfo) throws -> CMSampleBuffer {
        guard let source = sample.imageBuffer else { throw RotationError.invalidSample }
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        // 旋轉後的來源尺寸（跟隨來源時即為輸出尺寸）。
        let rotatedWidth = rotateLeft ? sourceHeight : sourceWidth
        let rotatedHeight = rotateLeft ? sourceWidth : sourceHeight
        // 輸出畫布：固定政策用固定尺寸，native（canvas == nil）用來源尺寸。
        if let canvas {
            guard canvas.width.isFinite, canvas.height.isFinite,
                  canvas.width >= 1, canvas.height >= 1,
                  canvas.width <= 8192, canvas.height <= 8192 else { throw RotationError.canvasExceedsBudget }
        }
        let outWidth = canvas.map { Int($0.width) } ?? rotatedWidth
        let outHeight = canvas.map { Int($0.height) } ?? rotatedHeight
        // 疊加層一律以「輸出畫布」為座標系（錨點即畫布四角）。
        configuration.sourceWidth = sourceWidth
        configuration.sourceHeight = sourceHeight
        configuration.outputWidth = outWidth
        configuration.outputHeight = outHeight
        guard let poolLimit = VideoProcessingBudget.limit(width: outWidth, height: outHeight) else {
            throw RotationError.canvasExceedsBudget
        }
        configuration.poolLimit = poolLimit
        let overlayStart = ProcessInfo.processInfo.systemUptime
        var layer: (image: CGImage, origin: CGPoint, size: CGSize)?
        do { layer = try overlay?.layer(canvas: CGSize(width: outWidth, height: outHeight)) }
        catch {
            // 時間文字是可選資訊，失敗不應阻斷正常影片；摘要累計降級次數。
            configuration.overlayDegraded = true
        }
        configuration.overlay = layer != nil
        configuration.overlayPrepareMs = (ProcessInfo.processInfo.systemUptime - overlayStart) * 1000
        let needsScale = outWidth != rotatedWidth || outHeight != rotatedHeight
        // 無旋轉、無縮放、無疊加 → 原樣返回，省一次 GPU pass。
        if !rotateLeft, !needsScale, layer == nil { bypass = true; return sample }

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
        let allocationStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: poolLimit] as CFDictionary, &destination)
        configuration.poolExhausted = allocationStatus == kCVReturnWouldExceedAllocationThreshold
        try check(allocationStatus)
        guard let destination else { throw RotationError.invalidSample }

        var image = CIImage(cvPixelBuffer: source)
        let sourceSpace = image.colorSpace
        let colorSpace = sourceSpace?.model == .rgb ? sourceSpace : CGColorSpace(name: CGColorSpace.sRGB)
        configuration.sourceColorSpace = sourceSpace?.model == .rgb
        if rotateLeft { image = image.oriented(.left) }
        // 明確限制輸出範圍，縮放與黑邊由此處決定，不依賴 render 自動縮放。
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
        if let layer {
            // Core Image 使用左下原點；設定錨點為左上原點。
            let y = CGFloat(outHeight) - layer.origin.y - layer.size.height
            let overlayImage = CIImage(cgImage: layer.image)
                .transformed(by: CGAffineTransform(translationX: layer.origin.x, y: y))
            image = overlayImage.composited(over: image)
        }
        let renderStart = ProcessInfo.processInfo.systemUptime
        context.render(image, to: destination, bounds: canvasRect, colorSpace: colorSpace)
        configuration.renderMs = (ProcessInfo.processInfo.systemUptime - renderStart) * 1000
        // 池會重用 buffer；先清除舊附件，再標記實際使用的 RGB 色彩空間。
        // 不複製來源 YUV matrix/range 或 HDR metadata 到 8-bit BGRA。
        CVBufferRemoveAllAttachments(destination)
        if let colorSpace {
            CVBufferSetAttachment(destination, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
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

    private func check(_ status: Int32) throws {
        if status != 0 { throw RotationError.status(status) }
    }
    private enum RotationError: Error { case unavailable, invalidSample, canvasExceedsBudget, status(Int32) }
}
#endif
