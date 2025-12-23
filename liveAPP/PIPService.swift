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











// =========================
// PIPService - Ultimate Version
// =========================

final class PIPService: NSObject, @unchecked Sendable {
    static let shared = PIPService()
    private override init() { }

    var isAnimatingMessages = false

    private var messagesLayer: PIPServiceMessages?

    // MARK: 時間顯示
    private func drawTimeOverlay(in cg: CGContext, size: CGSize) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "yyyy/MM/dd aHH:mm:ss"

        let timeText = formatter.string(from: Date())

        let fontSize: CGFloat = 16
        let timeFont = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let labelFont = UIFont.systemFont(ofSize: fontSize, weight: .medium)

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
            x: (size.width - textSize.width) / 2 - paddingX,   // 水平置中
            y: 40, // 往下移，避免遮到左上按鈕，可調整
            width: textSize.width + paddingX * 2,
            height: textSize.height + paddingY * 2
        )

        // 畫背景
        cg.setFillColor(UIColor.black.withAlphaComponent(0.45).cgColor)
        cg.fill(bgRect)

        // 畫文字
        UIGraphicsPushContext(cg)
        let textPoint = CGPoint(x: bgRect.minX + paddingX, y: bgRect.minY + paddingY)
        fullLine.draw(at: textPoint)
        UIGraphicsPopContext()
    }

    private func createPixelBuffer(from cgImage: CGImage, size: CGSize) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary

        guard CVPixelBufferCreate(kCFAllocatorDefault,
                                  Int(size.width),
                                  Int(size.height),
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
                                   width: Int(size.width),
                                   height: Int(size.height),
                                   bitsPerComponent: 8,
                                   bytesPerRow: bytesPerRow,
                                   space: colorSpace,
                                   bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) {
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: Int(size.width), height: Int(size.height)))
        }

        return pb
    }

    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDesc) == noErr,
              let fmt = formatDesc else { return nil }




        let now = CACurrentMediaTime()
        if self.basePTS == nil { self.basePTS = now }
        let relativeTime = now - (self.basePTS ?? now)
        let delta = now - self.lastRenderTime
        let pts = CMTime(seconds: relativeTime, preferredTimescale: 600)
        let duration = CMTime(seconds: delta, preferredTimescale: 600)
        var timing = CMSampleTimingInfo(duration: duration,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        self.lastRenderTime = now


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

    private var lastHashTime: CFTimeInterval = 0
    private let hashInterval: CFTimeInterval = 0.5
    // 每 0.5 秒計算一次 hash

    private var debugImageView: UIImageView?
    private let pipStartThreshold: Int64 = 1 

    // MARK: - Adaptive FPS
    private var currentFPS: Double = 30

    private let defaultFPS: Double = 1       // 平常 FPS
    private let decayRate: Double = 0.95     // 每次渲染衰減比例

    private var lastRenderTime = CACurrentMediaTime()
    private var lastImageHash: UInt64 = 0

    private var lastRenderedHash: UInt64 = 0
    private var previousImage: CGImage?

    var isMark = false

    private var decayDeadline: DispatchTime?
    private let decayDelay: TimeInterval = 0.8

    private var decayTimer: DispatchSourceTimer?

    @MainActor
    func startDecayAfterAnimation() {
        startDecayTimer()
    }
   

    // 自動調降FPS
    private func startDecayTimer() {
        if decayTimer == nil {
            decayTimer = DispatchSource.makeTimerSource(queue: renderQueue)
            decayTimer?.schedule(deadline: .now() + 0.2, repeating: 0.2)
            decayTimer?.setEventHandler { [weak self] in
                guard let self = self else { return }

                // 檢查是否到期
                if let deadline = self.decayDeadline, .now() >= deadline {

                    if self.currentFPS > self.defaultFPS {
                        self.currentFPS = max(self.defaultFPS, self.currentFPS * self.decayRate)
                        PIPLogTo("📉 decay fps -> \(self.currentFPS)")
                    }

                }

            }
            decayTimer?.resume()
        }
    }



    func markDirty() {
        lastRenderedHash = 0 // force renderIncremental 渲染新畫面
        isMark = true
        currentFPS = 60      // 事件觸發時暫時提升 FPS
        decayDeadline = .now() + decayDelay

    }

    // MARK: 快速圖片計算
    private func imageHash(_ cgImage: CGImage) -> UInt64 {
//        let width = thumbSize.width
//        let height = thumbSize.height

        let renderer = UIGraphicsImageRenderer(size: thumbSize)
        let img = renderer.image { ctx in
            ctx.cgContext.draw(
                cgImage,
                in: CGRect(origin: .zero, size: thumbSize)
            )
        }

        guard let data = img.cgImage?.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return 0 }

        var hash: UInt64 = 0
        let count = CFDataGetLength(data)
        for i in stride(from: 0, to: count, by: 16) {
            hash &+= UInt64(ptr[i])
        }
        return hash
    }



    
    // MARK: 動態調整
    private func adjustFPS(newHash: UInt64) {
        lastImageHash = newHash

        if !isMark {

            // 平滑衰減
            currentFPS = max(defaultFPS, currentFPS * decayRate)
        }

        PIPLogTo("📉 adaptive fps -> \(currentFPS)")
    }


    func setupDebugImageView(in parentView: UIView, frame: CGRect) {
        let imageView = UIImageView(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .lightGray
        parentView.addSubview(imageView)
        self.debugImageView = imageView
    }

    private var renderTimer: DispatchSourceTimer?
    var messagesContainerView: UIView?

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?

    private var basePTS: CFTimeInterval?

    private let dummyDelegate = DummyPlaybackDelegate()
    private let renderQueue = DispatchQueue(label: "com.pip.render", qos: .userInteractive)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    var frameSize: CGSize = .zero

    private var frameCount: Int64 = 0


    private let thumbSize = CGSize(width: 64, height: 64)

    private let renderScale = UIScreen.main.scale

    private var lastDebugUpdate: CFTimeInterval = 0


    // MARK: - Audio
    func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothHFP])
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
                giftURL: giftURL,isMain: isMain
            )


    }



    // MARK: - Start PiP
    @MainActor
    func startPiP(size: CGSize = CGSize(width: 300, height: 200)) {
        stopPiP()
        setupAudioSession()

        self.frameSize = size
        self.frameCount = 0


        // 建立容器 UIView
            let containerView = UIView(frame: CGRect(origin: .zero, size: size))
            containerView.backgroundColor = .clear
            containerView.isOpaque = false
            self.messagesContainerView = containerView

            if let window = UIApplication.shared
                .connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first?
                .windows
                .first {
                window.backgroundColor = .clear
                window.addSubview(containerView)
            }

            // 建立訊息 Layer
            messagesLayer = PIPServiceMessages(size: size)
            if let messagesLayer = messagesLayer {
                containerView.layer.addSublayer(messagesLayer.container)
            }



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
                layer.frame = CGRect(origin: .zero, size: self.frameSize)

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
            renderTimer?.schedule(deadline: .now(), repeating: 1.0/60.0)
            // 固定 60FPS timer
            renderTimer?.setEventHandler { [weak self] in
                guard let self = self else { return }

                let now = CACurrentMediaTime()
                let elapsed = now - self.lastRenderTime
                if elapsed >= 1.0 / self.currentFPS {
                    _ = self.renderIncremental()
                    self.lastRenderTime = now
                }
            }
            renderTimer?.resume()
        }
    }


    func cleanupMessagesContainer() {
        // 移除所有子層
        messagesContainerView?.layer.sublayers?.forEach { $0.removeFromSuperlayer() }

        // 從 superview 移除
        messagesContainerView?.removeFromSuperview()

        // 清空引用
        messagesContainerView = nil
    }
    // MARK: - Stop PiP
    func stopPiP() {
        renderTimer?.cancel()
        renderTimer = nil
        self.pipController?.stopPictureInPicture()
        self.pipController = nil
        self.displayLayer?.removeFromSuperlayer()
        self.displayLayer = nil

        self.frameCount = 0
        didStartPiP = false

        previousImage = nil
        lastRenderTime = CACurrentMediaTime()
        basePTS = nil

        cleanupMessagesContainer()

        decayTimer?.cancel()
        decayTimer = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }





    // MARK: - Incremental Render
    private func renderIncremental() -> Bool {

        guard let containerView = messagesContainerView, let displayLayer = displayLayer else { return false }

        // 取得當前時間
        let now = CACurrentMediaTime()

        if !isAnimatingMessages {
            let elapsed = now - lastRenderTime
            if elapsed < 1.0 / currentFPS { return false } // 幀跳過
        }

        lastRenderTime = now

        let renderSize = frameSize   // ← 用 pt，不要乘 scale

        let shouldForceRender = isAnimatingMessages

        // 1️⃣ 在主線程渲染 UIView 成 CGImage（最小範圍）
        var newCGImage: CGImage?
        DispatchQueue.main.sync {

            let format = UIGraphicsImageRendererFormat.default()
            format.scale = renderScale
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
            newCGImage = renderer.image { ctx in

                let cg = ctx.cgContext
                //hosting.view.layer.render(in: cg)
                containerView.layer.render(in: cg)
                // 2️⃣ 再畫時間（疊在最上面）
                drawTimeOverlay(in: cg, size: renderSize)

            }.cgImage
        }


        guard let cgImage = newCGImage else { return false }



        // hash / pixelbuffer / samplebuffer 直接執行

            var hash = self.lastRenderedHash
            if CACurrentMediaTime() - self.lastHashTime > self.hashInterval {
                hash = self.imageHash(cgImage)
                self.lastHashTime = CACurrentMediaTime()
            }


        let shouldRender = shouldForceRender || (hash != self.lastRenderedHash)


            self.lastRenderedHash = hash
            self.adjustFPS(newHash: hash)

            if shouldRender {
                self.previousImage = cgImage
            }

            guard let imageToRender = self.previousImage else { return false }

            // 生成 PixelBuffer
        let imagePixelSize = CGSize(
            width: imageToRender.width,
            height: imageToRender.height
        )

        guard let pixelBuffer = self.createPixelBuffer(
            from: imageToRender,
            size: imagePixelSize
        ) else { return false }



            if self.basePTS == nil { self.basePTS = CACurrentMediaTime() }

            guard let sampleBuffer = self.createSampleBuffer(from: pixelBuffer) else { return false }

            // 3️⃣ 主線程 enqueue
            DispatchQueue.main.async {
                if displayLayer.isReadyForMoreMediaData {
                    displayLayer.enqueue(sampleBuffer)
                    self.frameCount += 1

                    // 更新 debugImageView
                    if CACurrentMediaTime() - self.lastDebugUpdate > 0.1 {
                        self.debugImageView?.image = UIImage(cgImage: imageToRender, scale: UIScreen.main.scale, orientation: .up)
                        self.lastDebugUpdate = CACurrentMediaTime()
                    }

                    // 啟動 PiP
                    if !self.didStartPiP && self.frameCount >= self.pipStartThreshold {
                        self.safeTryStartPiP()
                    }
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




