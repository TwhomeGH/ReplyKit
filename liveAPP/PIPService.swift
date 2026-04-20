import SwiftUI
import AVKit
import CoreVideo
import CoreImage

import UIKit




// =========================
// DummyPlaybackDelegate
// =========================
final class DummyPlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { return false }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }


}








actor PIPRenderPipeline {

    private weak var service: PIPService?
    private var isRunning = false
    private var needsRender = false

    init(service: PIPService) {
        self.service = service
    }

    func requestRender() {
        needsRender = true

        if !isRunning {
            isRunning = true
            Task {
                await loop()
            }
        }
    }


    private func loop() async {
        while needsRender {
            needsRender = false
            await renderOnce()
        }
        isRunning = false
    }

    @MainActor
    private func callRender(_ service: PIPService) async {
        _ = await service.renderIncremental()
    }

    private func renderOnce() async {
        guard let service else { return }

        await callRender(service)
    }
    
}

// =========================
// PIPService - Ultimate Version
// =========================

final class PIPService: NSObject, @unchecked Sendable {
    static let shared = PIPService()

    private override init() {

    }

    var lastFPS = 1.0
    private var renderPipeline: PIPRenderPipeline?

    var isAnimatingMessages = false

    private var pixelBufferPool: CVPixelBufferPool?
    private let pixelBufferPoolSize = 3  // 可根據 FPS 調整

    private let renderQueue = DispatchQueue(
        label: "com.pip.render",
        qos: .background
    )

    private func setupPixelBufferPool(size: CGSize) {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey as String: pixelBufferPoolSize
        ]


        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            attrs as CFDictionary,
            &pool
        )
        self.pixelBufferPool = pool
    }


    private var gpuRenderer: MessageGPURenderer?

    // MARK: GPU Render
    func renderIfNeeded() -> CVPixelBuffer?  {


        let pixelBuffer: CVPixelBuffer? = timeOverlayImage(size:frameSize)


        return pixelBuffer
    }



    private var messagesLayer: PIPServiceMessages?


    private func createPixelBuffer(from cgImage: CGImage, size: CGSize) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?


        let attrs: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary

        //logger.debug("CGImage:\(cgImage.width)x\(cgImage.height)")

        guard CVPixelBufferCreate(kCFAllocatorDefault,
                                  Int(cgImage.width),
                                  Int(cgImage.height),
                                  kCVPixelFormatType_32BGRA,
                                  attrs,
                                  &pixelBuffer) == kCVReturnSuccess,
              let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pb) else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let height = CVPixelBufferGetHeight(pb)
        memset(baseAddress, 0, bytesPerRow * height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()

        if let context = CGContext(data: baseAddress,
                                   width: Int(cgImage.width),
                                   height: Int(cgImage.height),
                                   bitsPerComponent: 8,
                                   bytesPerRow: bytesPerRow,
                                   space: colorSpace,
                                   bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) {

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: Int(cgImage.width), height: Int(cgImage.height)))
        }

        return pb
    }

    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer,
                                    overridePTS: CMTime? = nil
    ) -> CMSampleBuffer? {

        var formatDesc: CMVideoFormatDescription?

        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc) == noErr,
        let fmt = formatDesc else { return nil }


        let pts: CMTime
        let duration: CMTime


        let now = CACurrentMediaTime()

        if let overridePTS {
            pts = overridePTS
            duration = CMTime(seconds: 1.0 / max(currentFPS, 1), preferredTimescale: 600)
        } else {



            if basePTS == nil { basePTS = now }

            let relativeTime = now - (self.basePTS ?? now)
            let delta = now - self.lastRenderTime

            pts = CMTime(seconds: relativeTime, preferredTimescale: 600)
            duration = CMTime(seconds: delta, preferredTimescale: 600)


        }



        var timing = CMSampleTimingInfo(duration: duration,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)




        var sb: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                           imageBuffer: pixelBuffer,
                                           dataReady: true,
                                           makeDataReadyCallback: nil,
                                           refcon: nil,
                                           formatDescription: fmt,
                                           sampleTiming: &timing,
                                           sampleBufferOut: &sb)

        if let attachments = sb.flatMap({ CMSampleBufferGetSampleAttachmentsArray($0, createIfNecessary: true) }) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        return sb
    }



    private lazy var debugCIContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext()
    }()


    private var debugImageView: UIImageView?

    var debugDisplayLayer: AVSampleBufferDisplayLayer?

    private var lastDebugUpdate: CFTimeInterval = 0

    private let pipStartThreshold: Int64 = 1

    // MARK: - Adaptive FPS
    private var currentFPS: Double = 1

    private let defaultFPS: Double = 1       // 平常 FPS
    private let decayRate: Double = 0.70     // 每次渲染衰減比例 (越小越快降

    private var lastRenderTime = CACurrentMediaTime()


    var isMark = false

    private var decayDeadline: DispatchTime?
    private let decayDelay: TimeInterval = 3.0

    private var decayTimer: DispatchSourceTimer?

    @MainActor
    func startDecayAfterAnimation() {
        startDecayTimer()
    }


    // 自動調降FPS
    private func startDecayTimer() {
        if decayTimer == nil {
            decayTimer = DispatchSource.makeTimerSource(queue: renderQueue)
            decayTimer?.schedule(
                deadline: .now() + 0.2,
                repeating: 1.0,
                leeway: .milliseconds(100)
            )
            decayTimer?.setEventHandler { [weak self] in
                guard let self = self else { return }

                // 檢查是否到期
                if let deadline = self.decayDeadline, .now() >= deadline {

                    if self.currentFPS > self.defaultFPS {
                        self.currentFPS = max(self.defaultFPS, self.currentFPS * self.decayRate)

                        // 後續動態改 FPS，例如改成 30 FPS
                        renderTimer?
                            .schedule(
                                deadline: .now(),
                                repeating: 1 / self.currentFPS
                            )
                        
                        PIPLogTo("📉 decay fps -> \(self.currentFPS)")
                        lastFPS = currentFPS
                        
                    }

                }

            }
            decayTimer?.resume()
        }
    }


    func fadeTime(_ time:Double){
        messagesLayer?.fadeInterval = time
    }
    func scrollTime(_ time:Double){
        messagesLayer?.scrollSpeed = time
    }

    func markDirty() {

        isMark = true
        currentFPS = 60      // 事件觸發時暫時提升 FPS

        // 後續動態改 FPS，例如改成 60 FPS
        renderTimer?.schedule(deadline: .now(), repeating: 1/60)

        decayDeadline = .now() + decayDelay

    }

    func waitFade() {

        PIPLogTo("PIP 等待Fade中")
        isMark = true
        currentFPS = 2      // 事件觸發時暫時提升 FPS

        // 後續動態改 FPS，例如改成 60 FPS
        renderTimer?.schedule(deadline: .now(), repeating: 1/2)

        decayDeadline = .now() + decayDelay

    }




    func decyDead() {
        decayDeadline = .now() + decayDelay
    }



    // MARK: 動態調整
    private func adjustFPS() {

        if !isMark {

            // 平滑衰減
            currentFPS = max(defaultFPS, currentFPS * decayRate)
        }

        PIPLogTo("📉 adaptive fps -> \(currentFPS)")
    }


//    func setupDebugImageView(in parentView: UIView, frame: CGRect) {
//        let imageView = UIImageView(frame: frame)
//        imageView.contentMode = .scaleAspectFit
//        imageView.backgroundColor = .clear
//        parentView.addSubview(imageView)
//
//        self.debugImageView = imageView
//    }
//
//    func setupDebugDisplayLayer() {
//        let layer = AVSampleBufferDisplayLayer()
//
//        layer.videoGravity = .resizeAspect
//        layer.backgroundColor = #colorLiteral(red: 0.9372549057, green: 0.3490196168, blue: 0.1921568662, alpha: 1)
//
//        // ✅ 設置控制時間基準
//        var timebase: CMTimebase?
//        CMTimebaseCreateWithSourceClock(
//            allocator: kCFAllocatorDefault,
//            sourceClock: CMClockGetHostTimeClock(),
//            timebaseOut: &timebase
//        )
//        if let tb = timebase {
//            layer.controlTimebase = tb
//            CMTimebaseSetTime(tb, time: .zero)
//            CMTimebaseSetRate(tb, rate: 1.0)
//        }
//
//
//        self.debugDisplayLayer = layer
//
//        
//    }


    private var renderTimer: DispatchSourceTimer?

    var messagesContainerView: UIView?



    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?

    private var basePTS: CFTimeInterval?

    private let dummyDelegate = DummyPlaybackDelegate()


    var frameSize: CGSize = .zero
    var OframeSize:CGSize = .zero

    private var frameCount: Int64 = 0

    // MARK: - Audio
    func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [
                                        .mixWithOthers
                                    ]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            PIPLogTo("AVAudioSession setup error: \(error)")
        }
    }



    func addMessage(
        user: String = "測試",
        msg: String,
        imgURL: String? = nil,
        giftURL: String? = nil,
        isMain: Bool = true
    ) {
        // 1️⃣ 先生成 tuple，先不帶圖片

        messagesLayer?
            .addMessage(
                user: user,
                message: msg,
                imgURL: imgURL,
                giftURL: giftURL,isMain:isMain
            )


    }


    // Metal
    private let metalDevice = MTLCreateSystemDefaultDevice()!
    private var ciContext:CIContext?



    // MARK: 直播結束訊息框
    func roundedBadgeAttachment(
        text: String,
        font: UIFont,
        textColor: UIColor = .white,
        bgColor: UIColor = .systemRed,
        padding: UIEdgeInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
    ) -> NSAttributedString {

        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = textColor
        label.backgroundColor = bgColor
        label.textAlignment = .center
        label.layer.cornerRadius = (font.lineHeight + padding.top + padding.bottom) / 2
        label.clipsToBounds = true

        label.sizeToFit()
        label.frame = CGRect(
            x: 0,
            y: 0,
            width: label.bounds.width + padding.left + padding.right,
            height: label.bounds.height + padding.top + padding.bottom
        )

        UIGraphicsBeginImageContextWithOptions(label.bounds.size, false, 0)

        label.layer.render(in: UIGraphicsGetCurrentContext()!)

        let image = UIGraphicsGetImageFromCurrentImageContext()

        UIGraphicsEndImageContext()

        let attachment = NSTextAttachment()
        attachment.image = image

        // 垂直置中對齊文字
        attachment.bounds = CGRect(
            x: 0,
            y: (font.capHeight - label.bounds.height) / 2,
            width: label.bounds.width,
            height: label.bounds.height
        )

        return NSAttributedString(attachment: attachment)
    }

    private func viewerBadgeAttachment(font: UIFont) -> NSAttributedString? {
        guard let viewerCount = LPConfig.shared.streamViewerCount else {
            return nil
        }

        return roundedBadgeAttachment(
            text: " \(viewerCount) ",
            font: font,
            textColor: UIColor(white: 0.16, alpha: 1.0),
            bgColor: UIColor(white: 0.83, alpha: 1.0),
            padding: UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        )
    }

    func currentTimeString() -> String {
        let f = StaticFormatter.formatter
        f.dateFormat = "yyyy/MM/dd aHH:mm:ss"

        return f.string(from: Date())
    }

    // MARK: 時間顯示
    private func drawTimeOverlay(in cg: CGContext, size: CGSize) {

        var elapsedSeconds: Double = 0

        if let start = LPConfig.shared.streamStartTime {
            if !LPConfig.shared.StreamEnded {
                elapsedSeconds = Date().timeIntervalSince(start)
                LPConfig.shared.lastStreamTime = elapsedSeconds
            }
        }


        let totalSeconds = Int(LPConfig.shared.lastStreamTime)

        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        // 格式化成 04:00:00
        let elapsedString = String(format: "%02d:%02d:%02d", hours, minutes, seconds)


        // 建立字串屬性

        let elapsedFont = UIFont.monospacedDigitSystemFont(
            ofSize: 14,
            weight: .regular
        )

        let elapsedLabelFont = UIFont.systemFont(
            ofSize: 14
            , weight: .medium
        )

        let elapsedAttr = NSMutableAttributedString()

        let lightRed3 = #colorLiteral(red: 1.0, green: 0.6, blue: 0.6, alpha: 1.0)

        // 1️⃣ 插入圖標代替 "用時" / "已過"
        let imageAttachment = NSTextAttachment()
        imageAttachment.image = UIImage(systemName: "clock.fill")?.withTintColor(lightRed3, renderingMode: .alwaysOriginal)

        // 調整圖標大小對齊文字
        // 調整大小和垂直對齊
        let imageHeight: CGFloat = elapsedLabelFont.lineHeight  // 用文字高度一致
        let imageWidth: CGFloat = imageHeight
        // bounds.y 負值會把圖片往上頂對齊文字基線
        imageAttachment.bounds = CGRect(x: 0, y: (elapsedLabelFont.capHeight - imageHeight)/2, width: imageWidth, height: imageHeight)

        let imageString = NSAttributedString(attachment: imageAttachment)

        // "已過" 紅色
        elapsedAttr.append(imageString)

        // 數字白色
        elapsedAttr.append(NSAttributedString(
            string: elapsedString,
            attributes: [
                .font: elapsedFont,
                .foregroundColor: UIColor.white
            ]
        ))

        // "秒" 紅色
        elapsedAttr.append(NSAttributedString(
            string: " ",
            attributes: [
                .font: elapsedLabelFont,
                .foregroundColor: lightRed3
            ]
        ))

        if !LPConfig.shared.StreamEndMes.isEmpty {

            var EndColor = #colorLiteral(red: 1, green: 0.4538183808, blue: 0.1835401952, alpha: 1)
            if LPConfig.shared.StreamEnded {
                EndColor = #colorLiteral(red: 0.2549019754, green: 0.2745098174, blue: 0.3019607961, alpha: 1)
            }

            elapsedAttr.append(
                roundedBadgeAttachment(
                    text: " \(LPConfig.shared.StreamEndMes) ",
                    font: elapsedLabelFont,
                    bgColor:EndColor
                )
            )

            if let viewerBadge = viewerBadgeAttachment(font: elapsedLabelFont) {
                elapsedAttr.append(NSAttributedString(
                    string: " ",
                    attributes: [
                        .font: elapsedLabelFont,
                        .foregroundColor: UIColor.clear
                    ]
                ))
                elapsedAttr.append(viewerBadge)
            }
        }



        // 計算位置（上方偏右）
        //let elapsedSize = elapsedAttr.size()

        let elapsedPoint = CGPoint(
            x: 50 ,
            y: 20
        )


        let timeText = currentTimeString()

        let fontSize: CGFloat = 16

        let timeFont = UIFont.monospacedDigitSystemFont(
            ofSize: fontSize ,
            weight: .regular
        )

        let labelFont = UIFont.systemFont(
            ofSize: fontSize ,
            weight: .medium
        )

        // 組 attributed string：同一行
        let fullLine = NSMutableAttributedString()
        fullLine.append(NSAttributedString(
            string: "現在時間 ",
            attributes: [
                .font: labelFont,
                .foregroundColor: UIColor.systemCyan
            ]
        ))
        fullLine.append(NSAttributedString(
            string: timeText,
            attributes: [
                .font: timeFont,
                .foregroundColor: UIColor.white
            ]
        ))

        let textSize = fullLine.size()

        let paddingX: CGFloat = 6
        let paddingY: CGFloat = 4

        // 背景矩形
        let bgRect = CGRect(
            x: (size.width - textSize.width ) / 2 - paddingX,   // 水平置中
            y: 40 , // 往下移，避免遮到左上按鈕，可調整

            width: textSize.width  + paddingX * 2,
            height: textSize.height  + paddingY * 2

        )

        // 畫背景
        cg.setFillColor(UIColor.black.withAlphaComponent(0.45).cgColor)
        cg.fill(bgRect)

        // 畫文字

        let textPoint = CGPoint(x: bgRect.minX + paddingX, y: bgRect.minY + paddingY)



        UIGraphicsPushContext(cg)

        elapsedAttr.draw(at: elapsedPoint)
        fullLine.draw(at: textPoint)

        UIGraphicsPopContext()


    }


    private var cachedTimeImage: CGImage?
    private var lastTimeText: String = ""
    private var lastOverlaySignature: String = ""

    private func overlaySignature() -> String {
        let status = LPConfig.shared.StreamEndMes
        let viewerCount = LPConfig.shared.streamViewerCount.map(String.init) ?? ""
        let ended = LPConfig.shared.StreamEnded ? "1" : "0"
        return "\(status)|\(viewerCount)|\(ended)"
    }


    private func timeOverlayImage(size: CGSize) -> CVPixelBuffer? {

        let nowText = currentTimeString() // 你現在 formatter 那段
        let overlaySig = overlaySignature()

        if nowText == lastTimeText,
           overlaySig == lastOverlaySignature,
           let cached = cachedTimeImage,
           !isMark {
            logTo("使用Cache")

            let pixelBuffer = gpuRenderer?.render(
                time:CIImage(cgImage: cached),
                containerSize: frameSize
            )

            return pixelBuffer
        }

        lastTimeText = nowText
        lastOverlaySignature = overlaySig


        // 將 PixelBuffer 尺寸用原大小

        let renderer = UIGraphicsImageRenderer(size: size)

        let img = renderer.image { ctx in
            let cg = ctx.cgContext

            // ✅ 先畫 messagesLayer
            if let layer = messagesLayer?.container {
                layer.render(in: cg)
            }

            drawTimeOverlay(in: cg, size: frameSize)
        }

        guard let cgImage = img.cgImage else { return nil }

        let pixelBuffer = gpuRenderer?.render(
            time:CIImage(cgImage: cgImage),
            containerSize: frameSize
        )

//        let buffer = createPixelBuffer(from: cgImage, size: size)

        cachedTimeImage = cgImage
        isMark = false

        return pixelBuffer
       // let ci = CIImage(cgImage: img.cgImage!)

        //return ci

    }




    // CPU
    @MainActor
    private func renderUIViewToPixelBuffer(size: CGSize) -> CVPixelBuffer? {

        guard let pool = pixelBufferPool else { return nil }

        var pixelBuffer: CVPixelBuffer?

        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)

        guard let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }


        guard let baseAddress = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let height = CVPixelBufferGetHeight(pb)

        memset(baseAddress, 0, bytesPerRow * height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()


        guard let context = CGContext(
            data: baseAddress,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }


        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)


        // ✅ 這裡用 layer.render 而不是 drawHierarchy
        //view.layer.render(in: context)
        messagesLayer?.container.render(in: context)
        // 疊上時間
        drawTimeOverlay(in: context, size: size)


        return pb

    }





    // MARK: - Start PiP
    @MainActor
    func startPiP(
        size: CGSize = CGSize(width: 300, height: 200)
    ) {
        stopPiP()
        setupAudioSession()

        //setupDebugDisplayLayer()

        self.frameSize = size

        let pixelSize = CGSize(
            width: size.width * UIScreen.main.scale,
            height: size.height * UIScreen.main.scale
        )

        self.OframeSize = pixelSize

        self.renderPipeline = PIPRenderPipeline(service: self)

        ciContext = CIContext(mtlDevice: metalDevice)

        //setupPixelBufferPool(size: pixelSize)

        if let ciContext = ciContext {
            gpuRenderer = MessageGPURenderer(size: OframeSize, ciText: ciContext)
        }

        self.frameCount = 0


        // 建立容器 UIView 原來給訊息組用顯示用的 棄用
//        let containerView = UIView(
//            frame: CGRect(origin: .zero, size: size)
//        )
//
//        containerView.backgroundColor = .clear
//        containerView.isOpaque = false
//
//        self.messagesContainerView = containerView
//
//        if let window = UIApplication.shared
//            .connectedScenes
//            .compactMap({ $0 as? UIWindowScene })
//            .first?
//            .windows
//            .first {
//            window.backgroundColor = .clear
//            window.addSubview(containerView)
//        }

        // 建立訊息 Layer
        messagesLayer = PIPServiceMessages(
            size: size,
            scrollSpeed: LPConfig.shared
                .ScrollTime)

//        if let messagesLayer = messagesLayer {
//            containerView.layer.addSublayer(messagesLayer.container)
//        }



        // Display Layer
        let layer = AVSampleBufferDisplayLayer()

        layer.videoGravity = .resizeAspect

        layer.backgroundColor = UIColor.black.cgColor
        self.displayLayer = layer





        // PiP Controller
        self.pipController = AVPictureInPictureController(
            contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self.dummyDelegate)
        )

        self.pipController?.requiresLinearPlayback = false
        self.pipController?.setValue(1, forKey: "controlsStyle")

        self.pipController?.delegate = self

        // Attach displayLayer
        self.attachToForegroundWindow {
            PIPLogTo("OK Frame?")
            Task { @MainActor in

                self.startRenderTimer()
            }
        }

    }

    // MARK: - Attach displayLayer
    private func attachToForegroundWindow(completion: @escaping () -> Void) {

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.attachToForegroundWindow(completion: completion)
                }
                return
            }

            guard let layer = self.displayLayer else { return }

            if layer.superlayer == nil, let containerLayer = windowScene.windows.first?.rootViewController?.view.layer ?? windowScene.windows.first?.layer {

                containerLayer.addSublayer(layer)

                let displayFrame = CGRect(
                    origin: .zero,
                    size: self.frameSize
                ) // size = 300x200 或你 startPiP 的尺寸

                layer.frame = displayFrame


                // ControlTimebase
                if layer.controlTimebase == nil {
                    var timebase: CMTimebase?
                    CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
                    if let tb = timebase {
                        layer.controlTimebase = tb
                        CMTimebaseSetTime(tb, time: .zero)
                        CMTimebaseSetRate(tb, rate: 1.0)
                    }
                }

                

                layer.flushAndRemoveImage()
            }

            completion()
        }
    }

    // MARK: - Safe Start PiP
    private var didStartPiP = false
    private func safeTryStartPiP() {
        guard !didStartPiP else { return }
        DispatchQueue.main.async {
            guard let pip = self.pipController, pip.isPictureInPicturePossible else { return }
            pip.startPictureInPicture()
            self.didStartPiP = true
            PIPLogTo("PiP started successfully")
        }
    }

    // MARK: - Render Timer
    private func startRenderTimer() {
        renderQueue.async { [weak self] in
            self?.scheduleNextRender()
        }
    }


    private func scheduleNextRender() {
        if renderTimer == nil {
            renderTimer = DispatchSource.makeTimerSource(queue: renderQueue)

            renderTimer?.schedule(
                deadline: .now(), repeating: 1.0 / self.currentFPS ,
                leeway: .milliseconds(10)
            )

            // 固定 60FPS timer
            renderTimer?.setEventHandler { [weak self] in
                guard let self = self else { return }

                Task {
                    await self.renderPipeline?.requestRender()
                }
            }
            renderTimer?.resume()
        }
    }


    func cleanupMessageslayer() {

        messagesLayer?.canncel()
        messagesLayer = nil

    }
//    func cleanupMessagesContainer() {
//        // 移除所有子層
//        messagesContainerView?.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
//
//        // 從 superview 移除
//        messagesContainerView?.removeFromSuperview()
//
//        // 清空引用
//        messagesContainerView = nil
//    }

    // MARK: - Stop PiP
    func stopPiP() {
        renderTimer?.cancel()
        renderTimer = nil

        renderPipeline = nil

        self.pipController?.stopPictureInPicture()
        self.pipController = nil

        self.displayLayer?.removeFromSuperlayer()
        self.displayLayer = nil

        self.debugDisplayLayer?.removeFromSuperlayer()
        self.debugDisplayLayer = nil

        self.frameCount = 0
        didStartPiP = false

        lastRenderTime = CACurrentMediaTime()
        basePTS = nil


        gpuRenderer = nil

        // Clear GPU Resource
        ciContext = nil
        pixelBufferPool = nil
        cachedTimeImage = nil
        lastOverlaySignature = ""
        lastTimeText = ""

        cleanupMessageslayer()

        //cleanupMessagesContainer()

        decayTimer?.cancel()
        decayTimer = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }


    // MARK: - Incremental Render
    @MainActor
    func renderIncremental() async -> Bool {

        guard let displayLayer = displayLayer else { return false }

        // 取得當前時間
        let now = CACurrentMediaTime()


        lastRenderTime = now

        if lastFPS != currentFPS {
            PIPLogTo("NowPIP FPS:\(currentFPS)")
            lastFPS = currentFPS
        }



        // 生成 PixelBuffer
        var pixelBuffer: CVPixelBuffer?

        pixelBuffer = renderIfNeeded()

        guard let pixelBuffer = pixelBuffer else { return false }

        if self.basePTS == nil { self.basePTS = CACurrentMediaTime() }

        guard let sampleBuffer = createSampleBuffer(from: pixelBuffer) else {
            return false
        }


        // 3️⃣ 主線程 enqueue

        if displayLayer.isReadyForMoreMediaData {

            displayLayer.enqueue(sampleBuffer)
            self.frameCount += 1


//            if let debugLayer = debugDisplayLayer,
//               debugLayer.isReadyForMoreMediaData {
//                debugLayer.enqueue(sampleBuffer)
//            }
//
//            // 更新 debugImageView
//            if UIApplication.shared.applicationState == .active ,
//               CACurrentMediaTime() - self.lastDebugUpdate > 0.1 {
//
//                self.lastDebugUpdate = CACurrentMediaTime()
//
//
//            }

            // 啟動 PiP
            if !self.didStartPiP && self.frameCount >= self.pipStartThreshold {
                self.safeTryStartPiP()
            }

        }



        return true

    }

}



func PIPLogTo(_ message:String){
    if LPConfig.shared.PIPLog {
        sendlog(title:"[PIP]",message: message)
    }
}

func logTo(_ message:String){
    print(message)
    sendlog(message: message)
}
// =========================
// AVPictureInPictureControllerDelegate
// =========================
extension PIPService: AVPictureInPictureControllerDelegate {
    internal func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {


        logTo("PIP Open")


    }
    internal func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        logTo("PIP Stop")
        PIPService.shared.stopPiP()
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {

        logTo("PIP Error \(error)")
    }
}






final class PIPTestService: NSObject {
    static let shared = PIPTestService()
    private override init() {}

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?
    private var renderTimer: DispatchSourceTimer?
    private var frameCount: Int64 = 0
    private var didStartPiP = false
    private let pipStartThreshold: Int64 = 3
    private var frameSize: CGSize = CGSize(width: 300, height: 200)

    private let playbackDelegate = DummyPlaybackDelegate()

    // MARK: - Audio
    func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            logTo("AVAudioSession setup error: \(error)")
        }
    }
    // MARK: - Start PiP
    func startPiPTest(size: CGSize = CGSize(width: 300, height: 200)) {
        stopPiP()
        setupAudioSession()

        self.frameSize = size
        self.frameCount = 0
        self.didStartPiP = false

        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor

        layer.isOpaque = true


        // ⭐️⭐️⭐️ 正確建立 timebase ⭐️⭐️⭐️
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )

        if status == noErr, let tb = timebase {
            layer.controlTimebase = tb
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 1.0)
        } else {
            logTo("❌ Failed to create CMTimebase: \(status)")
        }



        self.displayLayer = layer

        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
           let window = windowScene.windows.first,
           let rootView = window.rootViewController?.view
        {
            rootView.layer.addSublayer(layer)
            layer.frame = CGRect(origin: .zero, size: size)

        }

        self.pipController = AVPictureInPictureController(
            contentSource: .init(
                sampleBufferDisplayLayer: layer,
                playbackDelegate: playbackDelegate
            )
        )
        self.pipController?.delegate = self

        // 先送幾幀白畫面
        for _ in 0..<5 {
            renderWhiteFrame()
        }

        startRenderTimer()
    }

    // MARK: - Render Timer
    private func startRenderTimer() {
        let queue = DispatchQueue(label: "com.pip.render", qos: .userInteractive)
        renderTimer = DispatchSource.makeTimerSource(queue: queue)
        renderTimer?.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        renderTimer?.setEventHandler { [weak self] in
            self?.renderWhiteFrame()
        }
        renderTimer?.resume()
    }

    // MARK: - Stop PiP
    func stopPiP() {
        renderTimer?.cancel()
        renderTimer = nil
        pipController?.stopPictureInPicture()
        pipController = nil
        displayLayer?.removeFromSuperlayer()
        displayLayer = nil
        frameCount = 0
        didStartPiP = false



        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - 渲染白畫面幀
    private func renderWhiteFrame() {
        guard let displayLayer = displayLayer else { return }

        let width = Int(frameSize.width)
        let height = Int(frameSize.height)
        var pixelBuffer: CVPixelBuffer?
        let attrs: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]   // ⭐️⭐️⭐️ 關鍵 ⭐️⭐️⭐️
        ] as CFDictionary

        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA, attrs, &pixelBuffer) == kCVReturnSuccess,
              let pb = pixelBuffer else { return }



        CVPixelBufferLockBaseAddress(pb, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pb) {
            // 填滿白色: ARGB => A=255, R=255, G=255, B=255
            let bufferPtr = baseAddress.assumingMemoryBound(to: UInt32.self)
            let count = CVPixelBufferGetDataSize(pb) / MemoryLayout<UInt32>.size
            for i in 0..<count {
                bufferPtr[i] = 0xFFFFFFFF
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        // Timing
        let duration = CMTime(value: 1, timescale: 30)
        let pts = CMTime(value: frameCount, timescale: 30)
        var timing = CMSampleTimingInfo(duration: duration,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)

        // SampleBuffer
        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pb,
                                                     formatDescriptionOut: &formatDesc)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                           imageBuffer: pb,
                                           dataReady: true,
                                           makeDataReadyCallback: nil,
                                           refcon: nil,
                                           formatDescription: formatDesc!,
                                           sampleTiming: &timing,
                                           sampleBufferOut: &sb)
        guard let sampleBuffer = sb else { return }


        // ⭐️⭐️⭐️ 就加在這裡 ⭐️⭐️⭐️
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dict = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }


        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }


            print("[R]status:", displayLayer.status.rawValue)
            print("ready:", displayLayer.isReadyForMoreMediaData)
            print("pip active:", pipController?.isPictureInPictureActive as Any)

            if displayLayer.isReadyForMoreMediaData {


                displayLayer.enqueue(sampleBuffer)
                self.frameCount += 1
                logTo("FrameC:\(frameCount)")


                if !self.didStartPiP && self.frameCount >= self.pipStartThreshold {
                    self.pipController?.startPictureInPicture()
                    self.didStartPiP = true
                }
            }
        }
    }
}



// =========================
// AVPictureInPictureControllerDelegate
// =========================
extension PIPTestService: AVPictureInPictureControllerDelegate {
    internal func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {

        logTo("PIP Open")
    }
    internal func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        logTo("PIP Stop")
        PIPService.shared.stopPiP()
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {

        logTo("PIP Error \(error)")
    }
}




