import SwiftUI
import AVKit
import CoreVideo

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

final class PIPService: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = PIPService()
    /// 診斷僅查詢已初始化的服務，不因取樣建立影像資源。
    private(set) static weak var diagnosticInstance: PIPService?

    private var isInBackground = false

    private override init() {
        super.init()
        Self.diagnosticInstance = self
    }

    var lastFPS = 1.0

    var isAnimatingMessages = false
    private var needsRedraw = true
    private var lastPeriodicRedraw: CFTimeInterval = CACurrentMediaTime()
    private var periodicRedrawInterval: CFTimeInterval { PIPDisplaySettings.clockSeconds }

    private var pixelBufferPool: CVPixelBufferPool?
    private let pixelBufferPoolSize = 3
    private var cachedFormatDescription: CMVideoFormatDescription?
    private var cachedFormatSize: CGSize = .zero
    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    private var cachedTimeString: String?
    private var cachedElapsedString: String?
    private var lastOverlayStreamEnded: Bool = false
    private var lastOverlayStreamEndMes: String = ""
    private var lastOverlayViewerCount: Int? = nil
    private var lastOverlayIsReconnecting: Bool = false

    // MARK: - Ad Overlay
    private var adOverlayUser: String?
    private var adOverlayText: String?
    private var adOverlayCleanText: String?
    private var adOverlayPages: [(text: String, range: NSRange)] = []
    private var adOverlayPageIndex: Int = 0
    private var adOverlayIconURL: String?
    private var adOverlayIconImage: UIImage?
    private var adOverlayEmojiURLs: [String] = []
    private var adOverlayEmojiPositions: [Int] = []
    private var adOverlayEmojiPositionMap: [Int: Int] = [:]
    private var adOverlayEmojiImages: [UIImage?] = []
    private var adOverlayStartTime: CFTimeInterval = 0
    private var adOverlayActive = false
    private var adOverlayLogSkipCounter: Int = 0
    private var adOverlayPageDuration: CFTimeInterval {
        max(1, LPConfig.shared.PIPAdOverlayDuration)
    }

    private func setupPixelBufferPool(size: CGSize) {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
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
        self.cachedFormatDescription = nil
        self.cachedFormatSize = .zero
    }

    // MARK: - Render
    @MainActor
    func renderIfNeeded() -> CVPixelBuffer?  {
            return renderUIViewToPixelBuffer(size: OframeSize)
    }

    private var messagesLayer: PIPServiceMessages?

    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer,
                                    overridePTS: CMTime? = nil
    ) -> CMSampleBuffer? {

        let size = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        if cachedFormatDescription == nil || cachedFormatSize != size {
            var formatDesc: CMVideoFormatDescription?

            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDesc) == noErr,
            let fmt = formatDesc else { return nil }

            cachedFormatDescription = fmt
            cachedFormatSize = size
        }

        guard let fmt = cachedFormatDescription else { return nil }

        let pts: CMTime
        let duration: CMTime

        let now = CACurrentMediaTime()

        if let overridePTS {
            pts = overridePTS
            duration = CMTime(seconds: PIPRenderPolicy.interval(for: currentFPS), preferredTimescale: 600)
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

        if let attachments = sb.flatMap({ CMSampleBufferGetSampleAttachmentsArray($0, createIfNecessary: true) }),
           CFArrayGetCount(attachments) > 0,
           let rawPtr = CFArrayGetValueAtIndex(attachments, 0) {
            let dict = unsafeBitCast(rawPtr, to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        return sb
    }

    var debugDisplayLayer: AVSampleBufferDisplayLayer?

    private let pipStartThreshold: Int64 = 1

    private var renderCancelled = true
    /// 包含正式播放器啟動等待階段，供測試服務互斥檢查。
    var isRunningOrStarting: Bool { !renderCancelled || isPiPActive || pipController != nil }
    private var renderGeneration = PIPRenderGeneration()
    private var pipSession = PIPRenderGeneration()
    private var scheduledRender: DispatchWorkItem?
    private var scheduledRenderDeadline: CFTimeInterval?
    private var renderStatsStarted = CACurrentMediaTime()
    /// 固定容量區間統計；不保存逐幀樣本，不受 PIPLog 開關影響。
    private var performanceSession = UUID()
    private var renderWorkSeconds = 0.0
    private var maxRenderMilliseconds = 0.0
    private var maxScheduleDelayMilliseconds = 0.0
    private var backpressureSkips = 0
    private var renderFailures = 0
    private var reusedFrames = 0
    private var renderAttempts = 0
    private var drawnFrames = 0
    private var statsInitialFrameCount: Int64 = 0

    // MARK: - 保活模式
    private(set) var isKeepaliveMode = false
    private var animationFPS: Double { PIPDisplaySettings.powerSaving ? 8 : PIPRenderPolicy.animationFPS }
    private var activeFPS: Double { PIPDisplaySettings.powerSaving ? 3 : PIPRenderPolicy.activeFPS }
    private let idleFPS = PIPRenderPolicy.idleFPS
    private var keepaliveFPS: Double { 1.0 / configuredKeepaliveSeconds }

    /// 每次讀取持久化值；缺值時預設五秒，診斷與排程共用同一份設定。
    private var configuredKeepaliveSeconds: Double {
        PIPRenderPolicy.keepaliveSeconds(userDefaults?.object(forKey: "pipKeepaliveSeconds") as? Double ?? 5)
    }

    /// 設定頁明確套用間隔時可延後或提前下一幀；一般訊息更新仍只提前排程。
    @MainActor func applyKeepaliveInterval() {
        guard isKeepaliveMode else { return }
        decayFPSIfNeeded()
        guard !renderCancelled else { return }
        scheduleNextRender(after: PIPRenderPolicy.interval(for: currentFPS))
        PIPLogTo("保活更新間隔設定：\(configuredKeepaliveSeconds) 秒，實際目標 FPS：\(currentFPS)")
    }

    private var currentFPS: Double = 2
    private var lastDrawnKeepaliveTime: String?
    private var lastRenderTime = CACurrentMediaTime()
    private var lastActiveRenderTime = CACurrentMediaTime()
    private let decayCooldown: CFTimeInterval = 2.0
    private var cachedPixelBuffer: CVPixelBuffer?
    private var contentGeneration = 0
    private var lastRenderedGeneration = -1

    func requestAnimationFPS() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.requestAnimationFPS() }
            return
        }
        guard !isKeepaliveMode || adOverlayActive else { return }
        lastActiveRenderTime = CACurrentMediaTime()
        let newFPS = messagesLayer?.isAnimating == true ? animationFPS : activeFPS
        guard abs(currentFPS - newFPS) > 0.1 else { return }
        currentFPS = newFPS
        rescheduleRenderTimer(fps: currentFPS)
        setNeedsRedraw()
        PIPLogTo("🎬 animation fps -> \(currentFPS)")
        lastFPS = currentFPS
    }

    func markOverlayDirty() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.markOverlayDirty() }
            return
        }
        guard !isKeepaliveMode || adOverlayActive else { return }
        lastActiveRenderTime = CACurrentMediaTime()
        currentFPS = max(currentFPS, activeFPS)
        rescheduleRenderTimer(fps: currentFPS)
        setNeedsRedraw()
    }

    /// 每幀重新評估目標頻率；下一次單次排程使用更新後的間隔。
    func decayFPSIfNeeded() {
        let now = CACurrentMediaTime()
        let baseFPS = PIPRenderPolicy.targetFPS(
            keepalive: isKeepaliveMode, overlay: adOverlayActive,
            animating: messagesLayer?.isAnimating == true,
            pendingMessages: messagesLayer.map { !$0.pendingSegments.isEmpty } ?? false,
            recentlyActive: (now - lastActiveRenderTime) < decayCooldown,
            keepaliveInterval: configuredKeepaliveSeconds
        )

        let targetFPS = isKeepaliveMode ? baseFPS : (baseFPS == PIPRenderPolicy.animationFPS ? animationFPS : (baseFPS == PIPRenderPolicy.activeFPS ? activeFPS : 1 / periodicRedrawInterval))
        if abs(currentFPS - targetFPS) > 0.000001 {
            currentFPS = targetFPS
            if lastFPS != currentFPS {
                PIPLogTo("📉 fps -> \(currentFPS)")
                lastFPS = currentFPS
            }
        }
    }

    func fadeTime(_ time:Double){
        messagesLayer?.fadeInterval = time
    }
    func scrollTime(_ time:Double){
        messagesLayer?.scrollSpeed = time
    }

    var messagesContainerView: UIView?

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?

    private var basePTS: CFTimeInterval?

    private let dummyDelegate = DummyPlaybackDelegate()

    var frameSize: CGSize = .zero
    var OframeSize:CGSize = .zero

    /// 僅供顯示：目前 PIP 輸出 pixel buffer pool 的估算佔用（BGRA）。
    var estimatedPixelBufferPoolMB: Double {
        guard OframeSize.width > 0, OframeSize.height > 0 else { return 0 }
        return Double(pixelBufferPoolSize) * Double(OframeSize.width) * Double(OframeSize.height) * 4 / 1024 / 1024
    }

    /// 只讀目前排程與影像池狀態；估算大小不是實際配置／常駐記憶體。
    var resourceDiagnosticSummary: String {
        "pipActive=\(isPiPActive) pipRenderScheduled=\(scheduledRender != nil) pipRenderCancelled=\(renderCancelled) pipTargetFPS=\(currentFPS) pipPoolRetained=\(pixelBufferPool != nil) pipPoolHeldEstimateMB=\(pixelBufferPool == nil ? 0 : estimatedPixelBufferPoolMB) pipPoolConfiguredEstimateMB=\(estimatedPixelBufferPoolMB)"
    }

    private var frameCount: Int64 = 0

    // MARK: - Audio
    func setupAudioSession() {
        CaptureAudioOwnership.shared.performUnlessCaptured {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default,
                                        options: [
                                            .mixWithOthers,
                                            .allowAirPlay
                                        ]
                )
                try session.setActive(true)
            } catch {
                PIPLogTo("AVAudioSession setup error: \(error)")
            }
        }
    }

    func setNeedsRedraw() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.setNeedsRedraw() }
            return
        }
        needsRedraw = true
        contentGeneration &+= 1
    }

    func forceRender() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.forceRender() }
            return
        }
        guard !renderCancelled else { return }
        setNeedsRedraw()
        scheduleNextRender(after: 0)
    }

    func addMessage(
        user: String = "測試",
        msg: String,
        imgURL: String? = nil,
        avatarImage: UIImage? = nil,
        giftURL: String? = nil,
        isMain: Bool = true
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.addMessage(user: user, msg: msg, imgURL: imgURL,
                                avatarImage: avatarImage, giftURL: giftURL, isMain: isMain)
            }
            return
        }
        guard !isKeepaliveMode else { return }
        if !isMain {
            switch PIPDisplaySettings.secondaryMode {
            case "hidden": return
            case "summary":
                // 不推斷事件種類，只顯示最新一筆；長文字單行截斷、不累積通知歷史。
                secondaryNotice = String("\(user)：\(msg)".split(whereSeparator: { $0.isNewline }).joined(separator: " ").prefix(240))
                secondaryDeadline = CACurrentMediaTime() + 5
                markOverlayDirty()
                return
            default: break
            }
        }
        messagesLayer?
            .addMessage(
                user: user,
                message: msg,
                imgURL: imgURL,
                avatarImage: avatarImage,
                giftURL: giftURL,isMain:isMain
            )
        setNeedsRedraw()
    }

    // MARK: - Ad Overlay
    // 顯示贊助/廣告覆蓋層，支援多頁文字與行內 emoji 圖片
    @MainActor
    func addAdOverlay(user: String, text: String, iconURL: String?, useTTS: Bool) {
        adOverlayUser = user
        adOverlayText = text
        adOverlayIconURL = iconURL
        adOverlayIconImage = nil
        adOverlayStartTime = CACurrentMediaTime()
        adOverlayActive = true

        // 推下聊天訊息，為 overlay 騰出空間
        messagesLayer?.setAdOverlayOffset(145)

        // 抽離文字中的圖片網址，用 \u{2003} 保留行內位置
        let (cleanText, emojiURLs, emojiPositions) = PIPServiceMessages.extractAllImageURLs(from: text, placeholder: "\u{2003}")
        adOverlayCleanText = cleanText
        adOverlayEmojiURLs = emojiURLs
        adOverlayEmojiPositions = emojiPositions
        adOverlayEmojiPositionMap = Dictionary(uniqueKeysWithValues: emojiPositions.enumerated().map { ($1, $0) })
        adOverlayEmojiImages = Array(repeating: nil, count: emojiURLs.count)

        PIPLogTo("AdOverlay: text='\(text)' clean='\(cleanText)' emojiURLs=\(emojiURLs) positions=\(emojiPositions)")

        // 計算可用文字區域，分頁
        let overlayFontSize = max(1, CGFloat(LPConfig.shared.PIPAdOverlayFontSize))
        let overlayUserFontSize = max(1, CGFloat(LPConfig.shared.PIPAdOverlayUserFontSize))
        let overlaySpacing = max(0, CGFloat(LPConfig.shared.PIPAdOverlaySpacing))
        let maxTextW = frameSize.width * 0.88 - 8 - 28 - 8 - 8 - 16 * CGFloat(min(emojiURLs.count, 4)) - 4
        let msgYOffset = 6 + UIFont.boldSystemFont(ofSize: overlayUserFontSize).lineHeight + overlaySpacing
        let msgH = max(52, 6 + UIFont.boldSystemFont(ofSize: overlayUserFontSize).lineHeight + overlaySpacing + UIFont.systemFont(ofSize: overlayFontSize).lineHeight * 2 + 4 + 4) - 4 - msgYOffset
        let rawPages = Self.splitAdText(cleanText, font: .systemFont(ofSize: overlayFontSize), width: maxTextW, height: max(1, msgH))
        var offset = 0
        var pages: [(text: String, range: NSRange)] = []
        for p in rawPages {
            let nsLen = (p as NSString).length
            pages.append((text: p, range: NSRange(location: offset, length: nsLen)))
            offset += nsLen
        }
        adOverlayPages = pages
        adOverlayPageIndex = 0
        PIPLogTo("AdOverlay: \(pages.count) page(s), frameSize=\(frameSize), maxTextW=\(maxTextW) msgH=\(msgH)")

        // 非同步載入 emoji 圖片
        for (idx, url) in emojiURLs.enumerated() {
            Task { [weak self] in
                await PiPImageCache.shared.loadImage(urlString: url) { image in
                    guard let self = self, idx < self.adOverlayEmojiImages.count else { return }
                    self.adOverlayEmojiImages[idx] = image
                    PIPLogTo("AdOverlay: emoji[\(idx)] loaded \(image != nil)")
                    self.setNeedsRedraw()
                }
            }
        }

        // 非同步載入贊助者頭像
        if let iconURL, !iconURL.isEmpty {
            Task { [weak self] in
                await PiPImageCache.shared.loadImage(urlString: iconURL) { image in
                    self?.adOverlayIconImage = image
                    self?.setNeedsRedraw()
                }
            }
        }

        setNeedsRedraw()
        requestAnimationFPS()
    }

    func clearAdOverlay() {
        adOverlayActive = false
        adOverlayText = nil
        adOverlayCleanText = nil
        adOverlayUser = nil
        adOverlayIconURL = nil
        adOverlayIconImage = nil

        adOverlayEmojiURLs.removeAll()
        adOverlayEmojiPositions.removeAll()
        adOverlayEmojiPositionMap.removeAll()
        adOverlayEmojiImages.removeAll()


        adOverlayPages.removeAll()
        adOverlayPageIndex = 0
        messagesLayer?.setAdOverlayOffset(0)
        PIPLogTo("AdOverlay: cleared")
    }

    private static func splitAdText(_ text: String, font: UIFont, width: CGFloat, height: CGFloat) -> [String] {
        guard !text.isEmpty else { return [] }
        let nsText = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let constraint = CGSize(width: max(1, width), height: .greatestFiniteMagnitude)

        let totalSize = nsText.boundingRect(with: constraint, options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
        if totalSize.height <= height { return [text] }

        let lineHeight = font.lineHeight
        let linesPerPage = max(1, Int(height / lineHeight))

        var pages: [String] = []
        var searchStart = 0

        while searchStart < nsText.length {
            var low = searchStart
            var high = nsText.length
            var best = searchStart

            while low < high {
                let mid = (low + high + 1) / 2
                let testRange = NSRange(location: searchStart, length: mid - searchStart)
                let testStr = nsText.substring(with: testRange)
                let testSize = (testStr as NSString).boundingRect(with: constraint, options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
                let testLines = Int(ceil(testSize.height / lineHeight))

                if testLines <= linesPerPage {
                    best = mid
                    low = mid
                } else {
                    high = mid - 1
                }
            }

            if best <= searchStart { break }
            let pageStr = nsText.substring(with: NSRange(location: searchStart, length: best - searchStart))
            pages.append(pageStr)
            searchStart = best
        }

        return pages.isEmpty ? [text] : pages
    }

    /// 固定容量的文字快取；日期／時區／語系變更會使鍵值失效。
    private var clockTextKey = ""
    private var clockText = ""
    private var secondaryNotice: String?
    private var secondaryDeadline: CFTimeInterval = 0
    private var chatImage: CGImage?
    private var chatImageGeneration = -1
    private var chatImageSize = CGSize.zero

    /// 設定變更時立即套用控制列樣式；未啟動 PiP 時只保存偏好。
    func applySystemControlsStyle() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.applySystemControlsStyle() }
            return
        }
        PIPSystemControls.apply(to: pipController)
    }

    /// 設定變更只調整已存在的服務，並作廢畫面快取。
    func applyDisplaySettings() {
        secondaryNotice = nil
        clockTextKey = ""
        chatImage = nil
        setNeedsRedraw()
        decayFPSIfNeeded()
        rescheduleRenderTimer(fps: currentFPS)
    }

    /// 依顯示週期分桶，動畫高頻繪製也不會反覆格式化同一秒。
    func currentTimeString() -> String {
        let date = Date()
        let interval = isKeepaliveMode ? 1 : periodicRedrawInterval
        let key = "\(floor(date.timeIntervalSince1970 / interval))|\(TimeZone.current.identifier)|\(Locale.current.identifier)"
        if key != clockTextKey {
            let f = StaticFormatter.formatter
            f.timeZone = .current
            f.locale = .current
            f.dateFormat = "yyyy/MM/dd aHH:mm:ss"
            clockText = f.string(from: date)
            clockTextKey = key
        }
        return clockText
    }

    // MARK: 時間顯示
    private func drawTimeOverlay(in cg: CGContext, size: CGSize) {

        let timeText = currentTimeString()
        if isKeepaliveMode && !adOverlayActive {
            let timeFont = UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .regular)
            let labelFont = UIFont.boldSystemFont(ofSize: 18)
            let timeSize = (timeText as NSString).size(withAttributes: [.font: timeFont])
            let labelSize = ("保活用子母工作中" as NSString).size(withAttributes: [.font: labelFont])
            let maxW = max(timeSize.width, labelSize.width) + 24
            let totalH = timeSize.height + labelSize.height + 16
            let x = (size.width - maxW) / 2
            let y = (size.height - totalH) / 2

            cg.saveGState()
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1.0, y: -1.0)

            cg.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
            cg.fill(CGRect(x: x, y: y, width: maxW, height: totalH))

            UIGraphicsPushContext(cg)

            (timeText as NSString).draw(
                at: CGPoint(x: x + (maxW - timeSize.width) / 2, y: y + 6),
                withAttributes: [.font: timeFont, .foregroundColor: UIColor.white]
            )
            ("保活用子母工作中" as NSString).draw(
                at: CGPoint(x: x + (maxW - labelSize.width) / 2, y: y + 6 + timeSize.height + 4),
                withAttributes: [.font: labelFont, .foregroundColor: UIColor.systemGreen]
            )
            UIGraphicsPopContext()
            cg.restoreGState()
            return
        }

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
        let elapsedString = String(format: "%02d:%02d:%02d", hours, minutes, seconds)

        let ended = LPConfig.shared.StreamEnded
        let endMes = LPConfig.shared.StreamEndMes
        let viewerCount = LPConfig.shared.streamViewerCount
        let isReconnecting = LPConfig.shared.isReconnecting

        cachedTimeString = timeText
        cachedElapsedString = elapsedString
        lastOverlayStreamEnded = ended
        lastOverlayStreamEndMes = endMes
        lastOverlayViewerCount = viewerCount
        lastOverlayIsReconnecting = isReconnecting

        let notice = CACurrentMediaTime() < secondaryDeadline ? secondaryNotice : nil
        let scene = PIPTimeOverlayRenderer.Scene(
            elapsedString: elapsedString,
            nowTimeText: timeText,
            nowTimeLabel: LPConfig.shared.PIPNowTimeLabel,
            statusText: endMes,
            statusEnded: ended,
            viewerCount: viewerCount,
            isReconnecting: isReconnecting,
            reconnectText: LPConfig.shared.reconnectStatus,
            secondaryNotice: notice
        )
        PIPTimeOverlayRenderer.draw(in: cg, size: size, scene: scene)
    }

    // MARK: - Ad Overlay Drawing
    private func drawAdOverlay(in cg: CGContext, size: CGSize) {
        guard adOverlayActive, adOverlayText != nil else { return }

        adOverlayLogSkipCounter += 1

        let elapsed = CACurrentMediaTime() - adOverlayStartTime
        let remaining = adOverlayPageDuration - elapsed

        if remaining <= 0 {
            let nextPage = adOverlayPageIndex + 1
            if nextPage < adOverlayPages.count {
                adOverlayPageIndex = nextPage
                adOverlayStartTime = CACurrentMediaTime()
            } else {
                clearAdOverlay()
            }
            return
        }

        guard adOverlayPageIndex < adOverlayPages.count else { return }
        let page = adOverlayPages[adOverlayPageIndex]
        let pageText = page.text

        let alpha: CGFloat = min(1.0, max(0, remaining / 0.5))

        PIPAdOverlayRenderer.draw(in: cg, size: size, scene: PIPAdOverlayRenderer.Scene(
            user: adOverlayUser ?? "贊助訊息",
            text: pageText,
            range: page.range,
            emojiPositionMap: adOverlayEmojiPositionMap,
            emojiImages: adOverlayEmojiImages,
            icon: adOverlayIconImage,
            alpha: alpha,
            userFontSize: CGFloat(LPConfig.shared.PIPAdOverlayUserFontSize),
            textFontSize: CGFloat(LPConfig.shared.PIPAdOverlayFontSize),
            spacing: CGFloat(LPConfig.shared.PIPAdOverlaySpacing),
            pageIndex: adOverlayPageIndex,
            pageCount: adOverlayPages.count,
            logSkipCounter: adOverlayLogSkipCounter
        ))
    }

    // CPU
    @MainActor
    private func renderUIViewToPixelBuffer(size: CGSize) -> CVPixelBuffer? {

        guard let pool = pixelBufferPool else { return nil }

        var pixelBuffer: CVPixelBuffer?

        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)

        guard let pb = pixelBuffer else { return nil }

        if self.frameCount % 300 == 0 { PIPLogTo("🎨 CPU render \(Int(OframeSize.width))x\(Int(OframeSize.height))") }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)

        guard let context = CGContext(
            data: baseAddress,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        let scale = UIScreen.main.scale

        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: scale, y: -scale)
        if !isKeepaliveMode {
            // 動畫直接繪製；靜止後只保留一張圖，不讓純時間更新重畫聊天室。
            if messagesLayer?.isAnimating == true {
                chatImage = nil
                messagesLayer?.container.render(in: context)
            } else {
                if chatImage == nil || chatImageGeneration != contentGeneration || chatImageSize != frameSize {
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = scale
                    chatImage = UIGraphicsImageRenderer(size: frameSize, format: format).image { imageContext in
                        messagesLayer?.container.render(in: imageContext.cgContext)
                    }.cgImage
                    chatImageGeneration = contentGeneration
                    chatImageSize = frameSize
                }
                if let chatImage {
                    UIGraphicsPushContext(context)
                    UIImage(cgImage: chatImage, scale: scale, orientation: .up).draw(in: CGRect(origin: .zero, size: frameSize))
                    UIGraphicsPopContext()
                }
            }
        }
        context.restoreGState()

        let overlayScale = isKeepaliveMode ? 1.0 : scale

        context.saveGState()
        context.scaleBy(x: overlayScale, y: overlayScale)
        drawTimeOverlay(in: context, size: frameSize)
        context.restoreGState()

        context.saveGState()
        context.scaleBy(x: overlayScale, y: overlayScale)
        drawAdOverlay(in: context, size: frameSize)
        context.restoreGState()

        return pb
    }

    // MARK: - Start PiP
    @MainActor
    func startPiP(
        size: CGSize = CGSize(width: 300, height: 200)
    ) {
        guard !PIPTestService.shared.isRunning else { return }
        stopPiP()
        setupAudioSession()
        currentFPS = idleFPS
        lastActiveRenderTime = -.infinity

        self.frameSize = size

        let pixelSize = CGSize(
            width: size.width * UIScreen.main.scale,
            height: size.height * UIScreen.main.scale
        )
        self.OframeSize = pixelSize

        setupPixelBufferPool(size: pixelSize)

        self.frameCount = 0

        messagesLayer = PIPServiceMessages(
            size: size,
            scrollSpeed: LPConfig.shared
                .ScrollTime)

        let layer = AVSampleBufferDisplayLayer()

        layer.videoGravity = .resizeAspect

        layer.backgroundColor = UIColor.black.cgColor
        self.displayLayer = layer

        self.pipController = AVPictureInPictureController(
            contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self.dummyDelegate)
        )

        self.pipController?.requiresLinearPlayback = false
        PIPSystemControls.apply(to: self.pipController)

        self.pipController?.delegate = self

        let session = pipSession.value
        self.attachToForegroundWindow {
            PIPLogTo("OK Frame?")
            Task { @MainActor in
                guard self.pipSession.accepts(session) else { return }
                self.startRenderTimer()
            }
        }
    }


    @MainActor
    func startKeepalivePiP(size: CGSize = CGSize(width: 300, height: 200)) {
        guard !PIPTestService.shared.isRunning else { return }
        stopPiP()
        isKeepaliveMode = true
        setupAudioSession()

        self.frameSize = size

        self.OframeSize = size

        setupPixelBufferPool(size: size)

        self.frameCount = 0
        needsRedraw = true
        lastDrawnKeepaliveTime = nil
        currentFPS = keepaliveFPS

        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        self.displayLayer = layer

        self.pipController = AVPictureInPictureController(
            contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self.dummyDelegate)
        )
        self.pipController?.requiresLinearPlayback = false
        PIPSystemControls.apply(to: self.pipController)
        self.pipController?.delegate = self

        let session = pipSession.value
        self.attachToForegroundWindow {
            PIPLogTo("Keepalive PiP started")
            Task { @MainActor in
                guard self.pipSession.accepts(session) else { return }
                self.startRenderTimer()
            }
        }
    }
    // MARK: - Attach displayLayer
    private func attachToForegroundWindow(completion: @escaping () -> Void) {
        let session = pipSession.value
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.pipSession.accepts(session) else { return }

            guard let layer = self.displayLayer else {
                completion()
                return
            }

            if layer.superlayer != nil {
                completion()
                return
            }

            let scenes = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            if let windowScene = scenes.first,
               let containerLayer = windowScene.windows.first?.rootViewController?.view.layer ?? windowScene.windows.first?.layer {

                containerLayer.addSublayer(layer)

                let displayFrame = CGRect(
                    origin: .zero,
                    size: self.frameSize
                )

                layer.frame = displayFrame

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
                completion()
            } else {
                PIPLogTo("沒有可用的 windowScene，延後重試")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.pipSession.accepts(session) else { return }
                    self.attachToForegroundWindow(completion: completion)
                }
            }
        }
    }

    func reAttachDisplayLayerIfNeeded() {
        guard let layer = displayLayer, layer.superlayer == nil else { return }
        PIPLogTo("displayLayer 遺失，重新 attach")
        attachToForegroundWindow {
            PIPLogTo("displayLayer 重新 attach 完成")
        }
    }

    // MARK: - Safe Start PiP
    @Published var isPiPActive = false
    private func safeTryStartPiP() {
        guard !isPiPActive else { return }
        let session = pipSession.value
        DispatchQueue.main.async {
            guard self.pipSession.accepts(session), !self.isPiPActive else { return }
            guard let pip = self.pipController, pip.isPictureInPicturePossible else { return }
            pip.startPictureInPicture()
            self.isPiPActive = true
            PIPLogTo("PiP started successfully")
        }
    }

    // MARK: - Render Timer
    /// 重設單次渲染排程與統計，立即安排首幀。
    private func startRenderTimer() {
        cancelRenderTimer()
        renderCancelled = false
        performanceSession = UUID()
        renderStatsStarted = CACurrentMediaTime()
        renderAttempts = 0
        drawnFrames = 0
        statsInitialFrameCount = frameCount
        scheduleNextRender(after: 0)
    }

    /// 安排唯一下一幀並以世代拒絕已取消的回呼；delay 為秒，nil 使用目前 FPS。
    private func scheduleNextRender(after delay: TimeInterval? = nil) {
        guard !renderCancelled else { return }
        let interval = delay ?? PIPRenderPolicy.interval(for: currentFPS)
        scheduledRender?.cancel()
        let token = renderGeneration.invalidate()
        scheduledRenderDeadline = CACurrentMediaTime() + interval
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard !self.renderCancelled, self.renderGeneration.accepts(token) else { return }
                if let deadline = self.scheduledRenderDeadline {
                    self.maxScheduleDelayMilliseconds = max(self.maxScheduleDelayMilliseconds,
                        max(0, CACurrentMediaTime() - deadline) * 1000)
                }
                self.scheduledRender = nil
                self.scheduledRenderDeadline = nil
                _ = self.renderIncremental()
                guard !self.renderCancelled, self.renderGeneration.accepts(token) else { return }
                self.scheduleNextRender()
            }
        }
        scheduledRender = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    /// 訊息更新只提前下一幀，不反覆延後而餓死渲染；fps 單位為每秒幀數。
    private func rescheduleRenderTimer(fps: Double) {
        guard !renderCancelled else { return }
        let interval = PIPRenderPolicy.interval(for: fps)
        // Incoming updates may bring a frame forward, but must not keep postponing it.
        guard let deadline = scheduledRenderDeadline,
              deadline > CACurrentMediaTime() + interval else { return }
        scheduleNextRender(after: interval)
    }

    /// 停止排程並作廢已送入主佇列但尚未執行的回呼。
    private func cancelRenderTimer() {
        if !renderCancelled { reportPerformance(reason: "scheduleStopped") }
        renderCancelled = true
        renderGeneration.invalidate()
        scheduledRender?.cancel()
        scheduledRender = nil
        scheduledRenderDeadline = nil
    }

    func cleanupMessageslayer() {
        messagesLayer?.canncel()
        messagesLayer = nil
    }

    // MARK: - Stop PiP
    func stopPiP() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.stopPiP() }
            return
        }
        pipSession.invalidate()
        cancelRenderTimer()
        isKeepaliveMode = false
        clearAdOverlay()

        self.pipController?.stopPictureInPicture()
        self.pipController = nil

        self.displayLayer?.removeFromSuperlayer()
        self.displayLayer = nil

        self.debugDisplayLayer?.removeFromSuperlayer()
        self.debugDisplayLayer = nil

        self.frameCount = 0
        isPiPActive = false

        lastRenderTime = CACurrentMediaTime()
        basePTS = nil

        pixelBufferPool = nil
        cachedFormatDescription = nil
        cachedFormatSize = .zero
        chatImage = nil
        secondaryNotice = nil
        cachedPixelBuffer = nil
        cachedTimeString = nil
        cachedElapsedString = nil
        lastDrawnKeepaliveTime = nil
        needsRedraw = true
        lastPeriodicRedraw = CACurrentMediaTime()

        cleanupMessageslayer()

        if !(userDefaults?.bool(forKey: "TTSEnabled") ?? false) {
            CaptureAudioOwnership.shared.performUnlessCaptured {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }

        // PiP 停止後若 App 仍在背景，排程下一次 BGTask（PiP 活躍期間不排程以節省預算）
        #if os(iOS)
        DispatchQueue.main.async {
            if UIApplication.shared.applicationState == .background {
                BackgroundTaskManager.shared.scheduleSocketRefresh()
            }
        }
        #endif
    }

    /// 每分鐘及停止時直接走持久化日誌；只統計同步函式佔用，不冒充 CPU／GPU 使用率。
    /// 背景凍結時無法準時回報，windowSeconds 保留真實經過時間。
    private func reportPerformance(reason: String) {
        guard renderAttempts > 0 else { return }
        let window = max(0.001, CACurrentMediaTime() - renderStatsStarted)
        let sent = max(0, frameCount - statsInitialFrameCount)
        let mean = renderWorkSeconds * 1000 / Double(renderAttempts)
        let busy = renderWorkSeconds / window * 100
        let chatBytes = chatImage.map { $0.bytesPerRow * $0.height } ?? 0
        let summary = "[PiPPerformance] schema=1 session=\(performanceSession) reason=\(reason) mode=\(isKeepaliveMode ? "keepalive" : "chat") active=\(isPiPActive) windowSeconds=\(String(format: "%.2f", window)) targetFPS=\(currentFPS) clockSeconds=\(periodicRedrawInterval) keepaliveSeconds=\(configuredKeepaliveSeconds) reducedAnimation=\(PIPDisplaySettings.powerSaving) attempts=\(renderAttempts) redraws=\(drawnFrames) enqueued=\(sent) reused=\(reusedFrames) enqueueFPS=\(String(format: "%.2f", Double(sent) / window)) workMeanMs=\(String(format: "%.3f", mean)) workMaxMs=\(String(format: "%.3f", maxRenderMilliseconds)) workerBusyPercent=\(String(format: "%.2f", busy)) scheduleDelayMaxMs=\(String(format: "%.3f", maxScheduleDelayMilliseconds)) backpressureSkips=\(backpressureSkips) renderFailures=\(renderFailures) chatCacheBytes=\(chatBytes) poolEstimateMB=\(pixelBufferPool == nil ? 0 : estimatedPixelBufferPoolMB)"
        // 基礎性能摘要不受總日誌開關限制，也不轉送遠端。
        AppLogPersister.shared.append(line: "\(formatTime()): liveApp:\(summary)")
        renderStatsStarted = CACurrentMediaTime()
        renderAttempts = 0
        drawnFrames = 0
        statsInitialFrameCount = frameCount
        renderWorkSeconds = 0
        maxRenderMilliseconds = 0
        maxScheduleDelayMilliseconds = 0
        backpressureSkips = 0
        renderFailures = 0
        reusedFrames = 0
    }

    // MARK: - Incremental Render
    @MainActor
    private func renderIncremental() -> Bool {

        let workStarted = CACurrentMediaTime()
        renderAttempts += 1
        defer {
            let work = max(0, CACurrentMediaTime() - workStarted)
            renderWorkSeconds += work
            maxRenderMilliseconds = max(maxRenderMilliseconds, work * 1000)
            if CACurrentMediaTime() - renderStatsStarted >= 60 {
                reportPerformance(reason: "periodic")
            }
        }

        guard let displayLayer = displayLayer else {
            ensureDisplayLayerAttached()
            return false
        }

        guard displayLayer.isReadyForMoreMediaData else {
            backpressureSkips += 1
            decayFPSIfNeeded()
            return false
        }

        if secondaryNotice != nil, CACurrentMediaTime() >= secondaryDeadline {
            secondaryNotice = nil
            needsRedraw = true
        }
        let wasAnimating = messagesLayer?.tickAnimation() == true
        if wasAnimating { chatImage = nil }
        if wasAnimating {
            requestAnimationFPS()
        }
        if adOverlayActive { needsRedraw = true }

        let now = CACurrentMediaTime()
        var periodicRedraw = false
        if isKeepaliveMode {
            if !needsRedraw && currentTimeString() != lastDrawnKeepaliveTime {
                needsRedraw = true
            }
        } else {
            periodicRedraw = !needsRedraw && !wasAnimating && (now - lastPeriodicRedraw) >= periodicRedrawInterval
            if periodicRedraw { needsRedraw = true }
        }

        guard needsRedraw || wasAnimating else {
            if let cached = cachedPixelBuffer, let sb = createSampleBuffer(from: cached) {
                displayLayer.enqueue(sb)
                reusedFrames += 1
                frameCount += 1
                lastRenderTime = CACurrentMediaTime()
                if !isPiPActive { safeTryStartPiP() }
            }
            decayFPSIfNeeded()
            return false
        }
        if periodicRedraw { lastPeriodicRedraw = now }

        var pixelBuffer: CVPixelBuffer?

        let hadAdOverlay = adOverlayActive
        pixelBuffer = renderIfNeeded()

        guard let pixelBuffer = pixelBuffer else {
            renderFailures += 1
            decayFPSIfNeeded()
            return false
        }
        drawnFrames += 1

        if self.basePTS == nil { self.basePTS = CACurrentMediaTime() }

        cachedPixelBuffer = pixelBuffer
        lastRenderedGeneration = contentGeneration
        guard let sampleBuffer = createSampleBuffer(from: pixelBuffer) else {
            renderFailures += 1
            decayFPSIfNeeded()
            return false
        }
        needsRedraw = false
        displayLayer.enqueue(sampleBuffer)
        self.frameCount += 1

        if !self.isPiPActive && self.frameCount >= self.pipStartThreshold {
            self.safeTryStartPiP()
        }

        lastRenderTime = CACurrentMediaTime()
        if isKeepaliveMode { lastDrawnKeepaliveTime = currentTimeString() }

        decayFPSIfNeeded()

        if hadAdOverlay && !adOverlayActive {
            // Replace the final overlay frame before returning to the five-second cadence.
            forceRender()
        }

        return true
    }

    func appDidEnterBackground() {
        isInBackground = true
        if isPiPActive {
            PIPLogTo("PiP active 進入背景（audio mode 保持存活）")
        }
    }

    func appWillEnterForeground() {
        isInBackground = false
        reAttachDisplayLayerIfNeeded()

        if pixelBufferPool == nil && OframeSize.width > 0 && OframeSize.height > 0 {
            setupPixelBufferPool(size: OframeSize)
            PIPLogTo("重建 pixelBufferPool: \(OframeSize)")
        }

        setNeedsRedraw()
        forceRender()
        PIPLogTo("回到前景")
    }

    func releaseNonCriticalMemory() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.releaseNonCriticalMemory() }
            return
        }
        guard !isPiPActive else { return }
        cancelRenderTimer()
        pixelBufferPool = nil
        cachedFormatDescription = nil
        cachedFormatSize = .zero
        chatImage = nil
        secondaryNotice = nil
        cachedPixelBuffer = nil
        messagesLayer?.canncel()
        messagesLayer = nil
        cleanupMessageslayer()
    }

    func ensureDisplayLayerAttached() {
        guard let layer = displayLayer, layer.superlayer == nil, isPiPActive else { return }
        PIPLogTo("displayLayer 遺失，在 render 中重新 attach")
        DispatchQueue.main.async { [weak self] in
            self?.attachToForegroundWindow {}
        }
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
        guard pictureInPictureController === pipController else { return }
        logTo("PIP Open")
    }
    internal func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard pictureInPictureController === pipController else { return }
        logTo("PIP Stop")
        PIPService.shared.stopPiP()
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        logTo("PIP Error \(error)")
    }
}

/// 獨立測試播放器；生命週期由服務持有，離開操作頁不停止。
final class PIPTestService: NSObject, ObservableObject {
    static let shared = PIPTestService()
    private override init() {}

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?
    private var renderTimer: DispatchSourceTimer?
    private var frameCount: Int64 = 0
    /// 包含準備及啟動中；UI 依此禁止衝突操作，停止與失敗都清空。
    @Published private(set) var isRunning = false
    @Published private(set) var isPiPActive = false
    private var startRequested = false
    private var session = UUID()
    private let pipStartThreshold: Int64 = 3
    private var frameSize: CGSize = CGSize(width: 300, height: 200)

    private let playbackDelegate = DummyPlaybackDelegate()

    // MARK: - Audio
    func setupAudioSession() {
        CaptureAudioOwnership.shared.performUnlessCaptured {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .allowAirPlay])
                try session.setActive(true)
            } catch {
                logTo("AVAudioSession setup error: \(error)")
            }
        }
    }
    // MARK: - Start PiP
    func startPiPTest(size: CGSize = CGSize(width: 300, height: 200)) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.startPiPTest(size: size) }
            return
        }
        guard !isRunning, PIPService.diagnosticInstance?.isRunningOrStarting != true else { return }
        session = UUID()
        let token = session
        isRunning = true
        startRequested = false
        // 啟動未得到成功回呼時釋放互斥與計時器，不讓測試永久卡住。
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.session == token, self.isRunning, !self.isPiPActive else { return }
            self.stopPiP()
        }
        setupAudioSession()

        self.frameSize = size
        self.frameCount = 0
        self.isPiPActive = false

        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor

        layer.isOpaque = true

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
            logTo("Failed to create CMTimebase: \(status)")
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

        for _ in 0..<5 {
            renderWhiteFrame()
        }

        startRenderTimer()
    }

    // MARK: - Render Timer
    private func startRenderTimer() {
        // 測試狀態、顯示層與 UI 統一由主佇列管理。
        let queue = DispatchQueue.main
        renderTimer = DispatchSource.makeTimerSource(queue: queue)
        renderTimer?.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        renderTimer?.setEventHandler { [weak self] in
            self?.renderWhiteFrame()
        }
        renderTimer?.resume()
    }

    // MARK: - Stop PiP
    func stopPiP() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.stopPiP() }
            return
        }
        guard isRunning || pipController != nil else { return }
        session = UUID()
        isRunning = false
        startRequested = false
        renderTimer?.cancel()
        renderTimer = nil
        pipController?.stopPictureInPicture()
        pipController = nil
        displayLayer?.removeFromSuperlayer()
        displayLayer = nil
        frameCount = 0
        isPiPActive = false

        if !(userDefaults?.bool(forKey: "TTSEnabled") ?? false) {
            CaptureAudioOwnership.shared.performUnlessCaptured {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    // MARK: - 渲染白畫面幀
    private func renderWhiteFrame() {
        guard isRunning, let displayLayer = displayLayer else { return }
        let token = session

        let width = Int(frameSize.width)
        let height = Int(frameSize.height)
        var pixelBuffer: CVPixelBuffer?
        let attrs: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary

        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA, attrs, &pixelBuffer) == kCVReturnSuccess,
              let pb = pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(pb, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pb) {
            let bufferPtr = baseAddress.assumingMemoryBound(to: UInt32.self)
            let count = CVPixelBufferGetDataSize(pb) / MemoryLayout<UInt32>.size
            for i in 0..<count {
                bufferPtr[i] = 0xFFFFFFFF
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        let duration = CMTime(value: 1, timescale: 30)
        let pts = CMTime(value: frameCount, timescale: 30)
        var timing = CMSampleTimingInfo(duration: duration,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)

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
            guard let self, self.isRunning, self.session == token else { return }

            if displayLayer.isReadyForMoreMediaData {
                displayLayer.enqueue(sampleBuffer)
                self.frameCount += 1


                if !self.startRequested && self.frameCount >= self.pipStartThreshold {
                    self.startRequested = true
                    self.pipController?.startPictureInPicture()
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
        guard pictureInPictureController === pipController, isRunning else { return }
        isPiPActive = true
        logTo("測試 PiP 已啟動")
    }
    internal func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard pictureInPictureController === pipController else { return }
        stopPiP()
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        guard pictureInPictureController === pipController else { return }
        logTo("測試 PiP 啟動失敗：\(error)")
        stopPiP()
    }
}
