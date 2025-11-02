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
        return CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 60))
        //CMTimeRange(start: .zero, duration: .positiveInfinity)
    }


}

// =========================
// PIPService - Ultimate Version
// =========================


final class PIPService: NSObject {
    static let shared = PIPService()
    private override init() {

    }

    // MARK: - Properties
    private var debugWindow: UIWindow?
    private var debugImageView: UIImageView?
    private var enableDebugPreview: Bool = false

    private var renderTimer: DispatchSourceTimer?
    private var hostingController: UIHostingController<AnyView>?
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?

    private let dummyDelegate = DummyPlaybackDelegate()
    private let renderQueue = DispatchQueue(label: "com.pip.render", qos: .userInteractive)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var frameSize: CGSize = .zero
    private var frameCount: Int64 = 0

    // --- 增量檢測 ---
    private var previousThumb: Data? = nil
    private let thumbSize = CGSize(width: 64, height: 64)

    // MARK: - Audio
    func setupAudioSession() {
        DispatchQueue.main.async {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord,
                                        mode: .default,
                                        options: [.mixWithOthers, .allowBluetooth])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                logTo("AVAudioSession setup error: \(error)")
            }
        }
    }

    // MARK: - Foreground Window
    private func foregroundWindow() -> UIWindow? {
        // 找到前景 Scene
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else {
            return nil
        }

        // 從該 Scene 取 key window
        return scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
    }

    // MARK: - Start PiP
    func startPiP<Content: View>(with content: Content,
                                 size: CGSize = CGSize(width: 300, height: 200),
                                 enableDebugPreview: Bool = false) {

        stopPiP()
        setupAudioSession()
        self.enableDebugPreview = enableDebugPreview
        self.frameSize = size
        self.frameCount = 0
        self.previousThumb = nil



        DispatchQueue.main.async {
            // Hosting Controller
            let hosting = UIHostingController(rootView: AnyView(content.frame(width: size.width, height: size.height)))
            hosting.view.backgroundColor = .clear
            hosting.view.frame = CGRect(origin: .zero, size: size)
            self.hostingController = hosting

            // Display Layer
            let layer = AVSampleBufferDisplayLayer()
            layer.videoGravity = .resizeAspect
            layer.backgroundColor = UIColor.clear.cgColor
            self.displayLayer = layer

            // PiP Controller
            self.pipController = AVPictureInPictureController(
                contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self.dummyDelegate)
            )
            self.pipController?.delegate = self

            // Debug 預覽
            if enableDebugPreview { self.setupDebugWindow(size: size) }

            // 延遲 attach，等待 scene active

            guard let hosting = self.hostingController,
                  let layer = self.displayLayer,
                  let window = self.foregroundWindow() else {
                 logTo("noWindow!!")
                return
            }


            if hosting.view.window == nil { window.addSubview(hosting.view) }
            hosting.view.frame = CGRect(origin: .zero, size: self.frameSize)

            if layer.superlayer == nil { window.layer.addSublayer(layer) }


            // 先送一個空幀增加成功率
            let emptyBuffer = self.makeEmptySampleBuffer(size: self.frameSize)
            layer.enqueue(emptyBuffer)

            // 嘗試啟動 PiP
            self.tryStartPiP()

            //self.attachWhenSceneActive()
            self.startRenderTimer()
        }
    }

    // MARK: - Attach to active scene
    private func attachWhenSceneActive(retries: Int = 10) {
        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let hosting = self.hostingController,
                  let layer = self.displayLayer,
                  let window = self.foregroundWindow() else {
                self.attachWhenSceneActive(retries: retries - 1)
                return
            }


                if hosting.view.window == nil { window.addSubview(hosting.view) }
                hosting.view.frame = CGRect(origin: .zero, size: self.frameSize)

                if layer.superlayer == nil { window.layer.addSublayer(layer) }


            // 先送一個空幀增加成功率
            let emptyBuffer = self.makeEmptySampleBuffer(size: self.frameSize)
            layer.enqueue(emptyBuffer)

            // 嘗試啟動 PiP
            logTo("TRY PIP")
            self.tryStartPiP()
        }
    }

    private func makeEmptySampleBuffer(size: CGSize) -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary

        CVPixelBufferCreate(kCFAllocatorDefault,
                            Int(size.width),
                            Int(size.height),
                            kCVPixelFormatType_32BGRA,
                            attrs,
                            &pixelBuffer)
        guard let pb = pixelBuffer else { fatalError("無法生成 PixelBuffer") }

        CVPixelBufferLockBaseAddress(pb, [])
        memset(CVPixelBufferGetBaseAddress(pb), 0, CVPixelBufferGetDataSize(pb))
        CVPixelBufferUnlockBaseAddress(pb, [])

        let pts = CMTime(value: 0, timescale: 30)
        let duration = CMTime(value: 1, timescale: 30)
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: pts)

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
        return sb!
    }

    // MARK: - Debug Window
    private func setupDebugWindow(size: CGSize) {
        DispatchQueue.main.async {
            self.debugWindow?.isHidden = true
            self.debugWindow = nil
            self.debugImageView = nil

            guard let window = self.foregroundWindow() else { return }

            let win = UIWindow(windowScene: window.windowScene!)
            win.windowLevel = .alert + 1
            win.frame = CGRect(x: 20, y: 300, width: size.width, height: size.height)
            win.backgroundColor = .clear
            win.isHidden = false

            let debugView = UIImageView(frame: CGRect(origin: .zero, size: size))
            debugView.contentMode = .scaleAspectFit
            debugView.layer.borderColor = UIColor.red.cgColor
            debugView.layer.borderWidth = 1
            debugView.backgroundColor = .black

            win.addSubview(debugView)
            win.makeKeyAndVisible()

            self.debugWindow = win
            self.debugImageView = debugView
        }
    }

    // MARK: - Render Timer + 智慧送幀
    private func startRenderTimer() {
        renderQueue.async { [weak self] in
            guard let self = self else { return }
            var currentFPS: Double = 30
            var noChangeCount = 0

            let timer = DispatchSource.makeTimerSource(queue: self.renderQueue)
            timer.schedule(deadline: .now(), repeating: 1.0 / currentFPS)
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                let didSendFrame = self.renderIncremental()

                if didSendFrame {
                    noChangeCount = 0
                    if currentFPS < 30 {
                        currentFPS = 30
                        timer.schedule(deadline: .now(), repeating: 1.0 / currentFPS)
                    }
                } else {
                    noChangeCount += 1
                    if noChangeCount > 3 && currentFPS != 1 {
                        currentFPS = 1
                        timer.schedule(deadline: .now(), repeating: 1.0 / currentFPS)
                    }
                }
            }
            timer.resume()
            self.renderTimer = timer
        }
    }

    // MARK: Stop PiP
    func stopPiP() {
        renderTimer?.cancel()
        renderTimer = nil

        self.pipController?.stopPictureInPicture()
        self.pipController = nil

        self.displayLayer?.removeFromSuperlayer()
        self.displayLayer = nil

        DispatchQueue.main.async {
            self.hostingController?.view.removeFromSuperview()
            self.hostingController = nil

            self.debugWindow?.isHidden = true
            self.debugWindow = nil
            self.debugImageView = nil
        }

        self.frameCount = 0
        self.previousThumb = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Try Start PiP
    func tryStartPiP() {
        guard let pip = pipController, pip.isPictureInPicturePossible else { return }
        pip.startPictureInPicture()
    }

    // MARK: 增量渲染
    private func renderIncremental() -> Bool {
        guard let hosting = hostingController,
              let displayLayer = displayLayer else { return false }

        var newThumbData: Data?
        var thumbChanged = false

        DispatchQueue.main.sync {
            let renderer = UIGraphicsImageRenderer(size: thumbSize)
            let thumbImage = renderer.image { ctx in hosting.view.layer.render(in: ctx.cgContext) }

            if let data = thumbImage.pngData() {
                newThumbData = data
                thumbChanged = (previousThumb != data)
            } else {
                thumbChanged = true
            }
        }

        if !thumbChanged { return false }
        previousThumb = newThumbData

        // full-resolution
        var cgImageFull: CGImage?
        DispatchQueue.main.sync {
            let renderer = UIGraphicsImageRenderer(size: frameSize)
            cgImageFull = renderer.image { ctx in hosting.view.layer.render(in: ctx.cgContext) }.cgImage
        }
        guard let cgImage = cgImageFull else { return false }

        if enableDebugPreview {
            DispatchQueue.main.async { self.debugImageView?.image = UIImage(cgImage: cgImage) }
        }

        // pixel buffer
        var pixelBuffer: CVPixelBuffer?
        let attrs: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary

        guard CVPixelBufferCreate(kCFAllocatorDefault,
                                  Int(frameSize.width),
                                  Int(frameSize.height),
                                  kCVPixelFormatType_32BGRA,
                                  attrs,
                                  &pixelBuffer) == kCVReturnSuccess,
              let pb = pixelBuffer else { return false }

        CVPixelBufferLockBaseAddress(pb, [])
        ciContext.render(CIImage(cgImage: cgImage), to: pb)
        CVPixelBufferUnlockBaseAddress(pb, [])

        let pts = CMTime(value: frameCount, timescale: 30)
        let duration = CMTime(value: 1, timescale: 30)
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: pts)

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
        guard let sampleBuffer = sb else { return false }

        DispatchQueue.main.async {
            if displayLayer.isReadyForMoreMediaData {
                displayLayer.enqueue(sampleBuffer)
                self.frameCount += 1
                if self.frameCount == 1 { self.tryStartPiP() }
            }
        }

        return true
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





//final class PIPServiceRR: NSObject {
//    static let shared = PIPServiceRR()
//    private override init() {}
//
//    private let dummyDelegate = DummyPlaybackDelegate()
//    private var playerLayer: AVPlayerLayer?
//    private var pipController: AVPictureInPictureController?
//    private var customView: UIView?
//    private var textView: UITextView?
//    private var displayLink: CADisplayLink?
//
//    func startPiP() {
//        guard AVPictureInPictureController.isPictureInPictureSupported() else {
//            print("❌ 裝置不支援 PiP")
//            return
//        }
//
//        setupAudioSession()
//        setupPlayer()
//        setupPiP()
//        setupCustomView()
//
//        
//        print("✅ PiP possible: \(pipController?.isPictureInPicturePossible ?? false)")
//
//        pipController?.startPictureInPicture()
//    }
//    func stopPIP(){
//        pipController?.startPictureInPicture()
//
//    }
//    private func setupAudioSession() {
//        do {
//            try AVAudioSession.sharedInstance().setCategory(.playback)
//            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
//        } catch {
//            print("❌ 音訊設定失敗：\(error)")
//        }
//    }
//
//    private func setupPlayer() {
//        let playerLayer = AVPlayerLayer()
//        playerLayer.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
//
//
//        guard let url = Bundle.main.url(forResource: "竖向视频", withExtension: "mp4") else { return }
//        let asset = AVAsset(url: url)
//        let item = AVPlayerItem(asset: asset)
//        let player = AVPlayer(playerItem: item)
//        player.isMuted = true
//        player.play()
//
//        playerLayer.player = player
//        self.playerLayer = playerLayer
//
//        // 加到主視窗（不顯示）
//        if let windowScene = UIApplication.shared.connectedScenes
//            .compactMap({ $0 as? UIWindowScene })
//            .first(where: { $0.activationState == .foregroundActive }),
//           let window = windowScene.windows.first {
//            window.layer.addSublayer(playerLayer)
//        }
//
//    }
//
//    private func setupPiP() {
//        guard let playerLayer = playerLayer else { return }
//        let pip = AVPictureInPictureController(playerLayer: playerLayer)
//
//        pip?.delegate = self
//        pip?.setValue(1, forKey: "controlsStyle") // 隱藏控制項
//        if #available(iOS 14.2, *) {
//            pip?.canStartPictureInPictureAutomaticallyFromInline = true
//        }
//        self.pipController = pip
//    }
//
//    private func setupCustomView() {
//        let view = UIView()
//        view.backgroundColor = .clear
//
//        let textView = UITextView()
//        textView.text = (0..<20).map { _ in "這是自定義內容" }.joined(separator: "\n")
//        textView.backgroundColor = .black
//        textView.textColor = .white
//        textView.isUserInteractionEnabled = false
//
//        view.addSubview(textView)
//        textView.frame = view.bounds
//        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
//
//        self.customView = view
//        self.textView = textView
//    }
//
//    private func startScrolling() {
//        displayLink?.invalidate()
//        displayLink = CADisplayLink(target: self, selector: #selector(scrollText))
//        displayLink?.preferredFramesPerSecond = 30
//        displayLink?.add(to: .main, forMode: .default)
//    }
//
//    private func stopScrolling() {
//        displayLink?.invalidate()
//        displayLink = nil
//    }
//
//    @objc private func scrollText() {
//        guard let textView = textView else { return }
//        let offsetY = textView.contentOffset.y + 1
//        if offsetY > textView.contentSize.height {
//            textView.contentOffset = .zero
//        } else {
//            textView.contentOffset = CGPoint(x: 0, y: offsetY)
//        }
//    }
//}
//
//extension PIPServiceRR: AVPictureInPictureControllerDelegate {
//    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
//
//        if let windowScene = UIApplication.shared.connectedScenes
//            .compactMap({ $0 as? UIWindowScene })
//            .first(where: { $0.activationState == .foregroundActive }),
//           let window = windowScene.windows.first,
//           let customView = customView {
//            window.addSubview(customView)
//            customView.frame = window.bounds
//            customView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
//        }
//
//    }
//
//
//
//    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
//        startScrolling()
//    }
//
//    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
//        stopScrolling()
//        customView?.removeFromSuperview()
//    }
//
//
//}
