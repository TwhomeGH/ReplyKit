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

    private var isInBackground = false

    private override init() {
        super.init()
    }

    @objc func handleMemoryWarning() {
        pixelBufferPool = nil
        cachedFormatDescription = nil
        cachedFormatSize = .zero
        messagesLayer?.clearAllMessages()
        clearAdOverlay()

        Task {
            await PiPImageCache.shared.clear()
        }

        setNeedsRedraw()
    }

    var lastFPS = 1.0

    var isAnimatingMessages = false
    private var needsRedraw = true
    private var lastPeriodicRedraw: CFTimeInterval = CACurrentMediaTime()
    private let periodicRedrawInterval: CFTimeInterval = 1.0

    private var pixelBufferPool: CVPixelBufferPool?
    private let pixelBufferPoolSize = 3
    private var cachedFormatDescription: CMVideoFormatDescription?
    private var cachedFormatSize: CGSize = .zero
    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    private let clockIcon = UIImage(systemName: "clock.fill")?.withTintColor(
        #colorLiteral(red: 1.0, green: 0.6, blue: 0.6, alpha: 1.0),
        renderingMode: .alwaysOriginal
    )
    private let viewerIcon = UIImage(systemName: "person.2.fill")
    private let reconnectIcon = UIImage(systemName: "antenna.radiowaves.left.and.right")
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
    private var adOverlayEmojiImages: [UIImage?] = []
    private var adOverlayStartTime: CFTimeInterval = 0
    private var adOverlayActive = false
    private var adOverlayPageDuration: CFTimeInterval {
        max(1, LPConfig.shared.PIPAdOverlayDuration)
    }

    private let renderQueue = DispatchQueue(
        label: "com.pip.render",
        qos: .default
    )

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

    private var renderCancelled = false

    // MARK: - 保活模式
    private(set) var isKeepaliveMode = false
    private let keepaliveFPS: Double = 0.1

    // MARK: - 穩定 FPS 管理
    private var currentFPS: Double = 1

    private let animationFPS: Double = 24
    private let activeFPS: Double = 10
    private let idleFPS: Double = 4

    private var lastRenderTime = CACurrentMediaTime()
    private var lastActiveRenderTime = CACurrentMediaTime()
    private let decayCooldown: CFTimeInterval = 2.0

    func requestAnimationFPS() {
        let newFPS = messagesLayer?.isAnimating == true ? animationFPS : activeFPS
        guard abs(currentFPS - newFPS) > 0.1 else { return }
        currentFPS = newFPS
        rescheduleRenderTimer(fps: currentFPS)
        setNeedsRedraw()
        PIPLogTo("🎬 animation fps -> \(currentFPS)")
        lastFPS = currentFPS
    }

    func markOverlayDirty() {
        currentFPS = max(currentFPS, activeFPS)
        rescheduleRenderTimer(fps: currentFPS)
        setNeedsRedraw()
    }

    func decayFPSIfNeeded() {
        guard !isKeepaliveMode else {
            if abs(currentFPS - keepaliveFPS) > 0.01 {
                currentFPS = keepaliveFPS
            }
            return
        }

        let now = CACurrentMediaTime()

        guard let messagesLayer = messagesLayer else {
            if currentFPS != idleFPS {
                currentFPS = idleFPS
            }
            return
        }

        let targetFPS: Double
        if messagesLayer.isAnimating {
            targetFPS = animationFPS
        } else if !messagesLayer.pendingSegments.isEmpty || (now - lastActiveRenderTime) < decayCooldown {
            targetFPS = activeFPS
        } else {
            targetFPS = idleFPS
        }

        if abs(currentFPS - targetFPS) > 0.1 {
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

    func setNeedsRedraw() {
        needsRedraw = true
    }

    func forceRender() {
        setNeedsRedraw()
        Task { @MainActor in
            await self.renderIncremental()
        }
    }

    func addMessage(
        user: String = "測試",
        msg: String,
        imgURL: String? = nil,
        giftURL: String? = nil,
        isMain: Bool = true
    ) {
        messagesLayer?
            .addMessage(
                user: user,
                message: msg,
                imgURL: imgURL,
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

    // MARK: 直播結束訊息框
    private func drawBadge(
        in cg: CGContext,
        text: String,
        font: UIFont,
        origin: CGPoint,
        textColor: UIColor,
        bgColor: UIColor,
        icon: UIImage? = nil,
        iconTintColor: UIColor? = nil,
        padding: UIEdgeInsets = UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
    ) -> CGFloat {
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let iconSize = icon.map { _ in max(font.lineHeight - 2, 10) } ?? 0
        let iconSpacing: CGFloat = icon == nil ? 0 : 4

        let rect = CGRect(
            x: origin.x,
            y: origin.y,
            width: ceil(textSize.width + padding.left + padding.right + iconSize + iconSpacing),
            height: ceil(textSize.height + padding.top + padding.bottom)
        )

        let path = UIBezierPath(
            roundedRect: rect,
            cornerRadius: rect.height * 0.5
        )
        cg.saveGState()
        cg.setFillColor(bgColor.cgColor)
        path.fill()
        cg.restoreGState()

        var textOriginX = rect.minX + padding.left

        if let icon {
            let textMidY = rect.minY + padding.top + font.lineHeight / 2
            let targetHeight = font.capHeight
            let aspectRatio = icon.size.width / icon.size.height
            let targetWidth = targetHeight * aspectRatio

            let iconRect = CGRect(
                x: textOriginX,
                y: textMidY - targetHeight / 2,
                width: targetWidth,
                height: targetHeight
            )

            icon.withTintColor(iconTintColor ?? textColor, renderingMode: .alwaysTemplate)
                .draw(in: iconRect)

            textOriginX += targetWidth + iconSpacing
        }

        let textPoint = CGPoint(
            x: textOriginX,
            y: rect.minY + padding.top
        )

        (text as NSString).draw(
            at: textPoint,
            withAttributes: [
                .font: font,
                .foregroundColor: textColor
            ]
        )

        return rect.width
    }

    func currentTimeString() -> String {
        let f = StaticFormatter.formatter
        f.dateFormat = "yyyy/MM/dd aHH:mm:ss"

        return f.string(from: Date())
    }

    // MARK: 時間顯示
    private func drawTimeOverlay(in cg: CGContext, size: CGSize) {

        let timeText = currentTimeString()
        if isKeepaliveMode {
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

        cg.saveGState()
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1.0, y: -1.0)

        let elapsedFont = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        let elapsedLabelFont = UIFont.systemFont(ofSize: 14, weight: .medium)

        let imageHeight: CGFloat = elapsedLabelFont.lineHeight
        let imageWidth: CGFloat = imageHeight
        let elapsedPoint = CGPoint(x: 50, y: 20)

        let fontSize: CGFloat = 16
        let timeFont = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let labelFont = UIFont.systemFont(ofSize: fontSize, weight: .medium)

        let fullLine = NSMutableAttributedString()
        fullLine.append(NSAttributedString(string: "現在時間 ", attributes: [.font: labelFont, .foregroundColor: UIColor.systemCyan]))
        fullLine.append(NSAttributedString(string: timeText, attributes: [.font: timeFont, .foregroundColor: UIColor.white]))

        let textSize = fullLine.size()
        let paddingX: CGFloat = 6
        let paddingY: CGFloat = 4
        let spacingY: CGFloat = 20

        let bgRect = CGRect(
            x: (size.width - textSize.width) / 2 - paddingX,
            y: elapsedPoint.y + spacingY,
            width: textSize.width + paddingX * 2,
            height: textSize.height + paddingY * 2
        )

        cg.setFillColor(UIColor.black.withAlphaComponent(0.45).cgColor)
        cg.fill(bgRect)

        let textPoint = CGPoint(x: bgRect.minX + paddingX, y: bgRect.maxY - paddingY - textSize.height)

        UIGraphicsPushContext(cg)

        clockIcon?.draw(in: CGRect(
            x: elapsedPoint.x,
            y: elapsedPoint.y + (elapsedFont.capHeight - imageHeight) * 0.5,
            width: imageWidth,
            height: imageHeight
        ))

        let timeTextPoint = CGPoint(
            x: elapsedPoint.x + imageWidth + 4,
            y: elapsedPoint.y + (elapsedFont.capHeight - elapsedFont.lineHeight) * 0.5
        )

        (elapsedString as NSString).draw(at: timeTextPoint, withAttributes: [.font: elapsedFont, .foregroundColor: UIColor.white])

        let elapsedTextSize = (elapsedString as NSString).size(withAttributes: [.font: elapsedFont])
        var badgeX = timeTextPoint.x + elapsedTextSize.width + 8
        let badgeY = timeTextPoint.y + (elapsedFont.capHeight - elapsedLabelFont.lineHeight) * 0.5

        if !endMes.isEmpty {
            var endColor = #colorLiteral(red: 1, green: 0.4538183808, blue: 0.1835401952, alpha: 1)
            if ended { endColor = #colorLiteral(red: 0.2549019754, green: 0.2745098174, blue: 0.3019607961, alpha: 1) }

            let statusWidth = drawBadge(in: cg, text: endMes, font: elapsedLabelFont,
                                        origin: CGPoint(x: badgeX, y: badgeY),
                                        textColor: .white, bgColor: endColor,
                                        padding: UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8))
            badgeX += statusWidth + 6
        }

        if let viewerCount = viewerCount {
            _ = drawBadge(in: cg, text: "\(viewerCount)", font: elapsedLabelFont,
                          origin: CGPoint(x: badgeX, y: badgeY),
                          textColor: UIColor(white: 0.16, alpha: 1.0),
                          bgColor: UIColor(white: 0.83, alpha: 1.0),
                          icon: viewerIcon,
                          iconTintColor: UIColor(white: 0.22, alpha: 1.0),
                          padding: UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8))
        }

        if isReconnecting {
            let reconnectBadgeY = bgRect.maxY + 8
            badgeX = timeTextPoint.x + elapsedTextSize.width + 8
            _ = drawBadge(in: cg, text: LPConfig.shared.reconnectStatus, font: elapsedLabelFont,
                          origin: CGPoint(x: badgeX, y: reconnectBadgeY),
                          textColor: .white,
                          bgColor: #colorLiteral(red: 1, green: 0.6, blue: 0, alpha: 1),
                          icon: reconnectIcon, iconTintColor: .white,
                          padding: UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8))
        }

        fullLine.draw(at: textPoint)

        UIGraphicsPopContext()
        cg.restoreGState()
    }

    // MARK: - Ad Overlay Drawing
    private func drawAdOverlay(in cg: CGContext, size: CGSize) {
        guard adOverlayActive, adOverlayText != nil else { return }

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

        cg.saveGState()
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1.0, y: -1.0)
        cg.setAlpha(alpha)

        let bannerW = size.width * 0.88
        let bannerX = (size.width - bannerW) / 2
        let bannerY: CGFloat = 85

        let labelFont = UIFont.boldSystemFont(ofSize: max(1, CGFloat(LPConfig.shared.PIPAdOverlayUserFontSize)))
        let overlayFontSize = max(1, CGFloat(LPConfig.shared.PIPAdOverlayFontSize))
        let textFont = UIFont.systemFont(ofSize: overlayFontSize)
        let overlaySpacing = max(0, CGFloat(LPConfig.shared.PIPAdOverlaySpacing))
        let bannerH: CGFloat = max(52, 6 + labelFont.lineHeight + overlaySpacing + textFont.lineHeight * 2 + 4 + 4)

        let bgRect = CGRect(x: bannerX, y: bannerY, width: bannerW, height: bannerH)
        let path = UIBezierPath(roundedRect: bgRect, cornerRadius: 10)
        cg.setFillColor(UIColor(red: 0.9, green: 0.55, blue: 0.05, alpha: 0.88).cgColor)
        path.fill()

        UIGraphicsPushContext(cg)

        let textX = iconX + iconSize + 8
        let textW = bannerW - (textX - bannerX) - 8

        let msgY = bannerY + 6 + labelFont.lineHeight + overlaySpacing
        let msgH = bannerY + bannerH - 4 - msgY

        let iconSize: CGFloat = 28
        let iconX = bannerX + 8
        // icon 垂直置中於整個文字區塊（名稱 + 間距 + 內文），視覺上與文字水平
        let textBlockCenter = (bannerY + 6) + (labelFont.lineHeight + overlaySpacing + msgH) / 2
        let iconY = textBlockCenter - iconSize / 2
        let iconRect = CGRect(x: iconX, y: iconY, width: iconSize, height: iconSize)

        if let icon = adOverlayIconImage {
            cg.saveGState()
            cg.addEllipse(in: iconRect)
            cg.clip()
            icon.draw(in: iconRect)
            cg.restoreGState()
        } else {
            UIImage(systemName: "star.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: iconRect)
        }

        let user = adOverlayUser ?? "贊助訊息"
        (user as NSString).draw(at: CGPoint(x: textX, y: bannerY + 6), withAttributes: [
            .font: labelFont,
            .foregroundColor: UIColor.white
        ])

        let msgRect = CGRect(x: textX, y: msgY, width: textW, height: msgH)

        // Draw text with inline emoji using Core Text
        // 流程：CTFrame 計算排版 → 逐行逐字元檢查是否為 emoji 位置 → 繪製 emoji 或文字
        let attrStr = NSAttributedString(string: pageText, attributes: [.font: textFont, .foregroundColor: UIColor(white: 1, alpha: 0.9)])
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let cgPathRect = CGRect(origin: .zero, size: msgRect.size)
        let cgPath = CGPath(rect: cgPathRect, transform: nil)
        let ctFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attrStr.length), cgPath, nil)
        let lines = CTFrameGetLines(ctFrame) as! [CTLine]
        var lineOrigins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(ctFrame, CFRange(location: 0, length: lines.count), &lineOrigins)

        PIPLogTo("AdOverlay: drawing page=\(adOverlayPageIndex)/\(adOverlayPages.count) range=\(page.range) text='\(pageText)' positions=\(adOverlayEmojiPositions) emojiLoaded=\(adOverlayEmojiImages.compactMap({ $0 != nil }).count)/\(adOverlayEmojiImages.count)")

        for (li, line) in lines.enumerated() {
            let lineOrigin = lineOrigins[li]
            let lineY = msgRect.origin.y + msgRect.height - lineOrigin.y - textFont.lineHeight
            let lineRange = CTLineGetStringRange(line)
            let lineStart = lineRange.location
            let lineEnd = lineRange.location + lineRange.length
            let nsPageText = pageText as NSString

            if li == 0 {
                PIPLogTo("AdOverlay: msgRect=\(msgRect) lineOrigin=\(lineOrigin) lineHeight=\(textFont.lineHeight) lineY=\(lineY)")
            }

            var charIdx = lineStart
            while charIdx < lineEnd {
                let globalPos = page.range.location + charIdx
                let foundEmojiPos = adOverlayEmojiPositions.firstIndex(of: globalPos)
                PIPLogTo("AdOverlay: charIdx=\(charIdx) globalPos=\(globalPos) posMatch=\(foundEmojiPos ?? -1) imgCount=\(adOverlayEmojiImages.count) imgLoaded=\(foundEmojiPos.map { $0 < adOverlayEmojiImages.count && adOverlayEmojiImages[$0] != nil } ?? false)")

                if let emojiIdx = foundEmojiPos,
                   emojiIdx < adOverlayEmojiImages.count,
                   let img = adOverlayEmojiImages[emojiIdx] {
                    // 此行有 emoji 圖片 → 繪製圖片
                    let emojiX = msgRect.origin.x + CTLineGetOffsetForStringIndex(line, charIdx, nil)
                    let emojiSize: CGFloat = overlayFontSize * 1.2
                    let emojiY = lineY + (textFont.lineHeight - emojiSize) / 2
                    img.draw(in: CGRect(x: emojiX, y: emojiY, width: emojiSize, height: emojiSize))
                    PIPLogTo("AdOverlay: emoji[\(emojiIdx)] at line=\(li) x=\(emojiX) y=\(emojiY)")
                    charIdx += 1
                } else {
                    // 一般文字區段 → 找出連續非 emoji 文字並繪製
                    var segEnd = charIdx + 1
                    while segEnd < lineEnd {
                        let nextGlobalPos = page.range.location + segEnd
                        if adOverlayEmojiPositions.contains(nextGlobalPos) { break }
                        segEnd += 1
                    }
                    let segRange = NSRange(location: charIdx, length: segEnd - charIdx)
                    let segStr = nsPageText.substring(with: segRange)
                    let textX = msgRect.origin.x + CTLineGetOffsetForStringIndex(line, charIdx, nil)
                    (segStr as NSString).draw(at: CGPoint(x: textX, y: lineY), withAttributes: [
                        .font: textFont,
                        .foregroundColor: UIColor(white: 1, alpha: 0.9)
                    ])
                    charIdx = segEnd
                }
            }
        }

        UIGraphicsPopContext()
        cg.restoreGState()
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
            messagesLayer?.container.render(in: context)
        }
        context.restoreGState()

        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        drawTimeOverlay(in: context, size: frameSize)
        context.restoreGState()

        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        drawAdOverlay(in: context, size: frameSize)
        context.restoreGState()

        return pb
    }

    // MARK: - Start PiP
    @MainActor
    func startPiP(
        size: CGSize = CGSize(width: 300, height: 200)
    ) {
        stopPiP()
        setupAudioSession()

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
        self.pipController?.setValue(1, forKey: "controlsStyle")

        self.pipController?.delegate = self

        self.attachToForegroundWindow {
            PIPLogTo("OK Frame?")
            Task { @MainActor in
                self.startRenderTimer()
            }
        }
    }


    @MainActor
    func startKeepalivePiP(size: CGSize = CGSize(width: 300, height: 200)) {
        stopPiP()
        isKeepaliveMode = true
        setupAudioSession()

        self.frameSize = size

        let pixelSize = CGSize(
            width: size.width * UIScreen.main.scale,
            height: size.height * UIScreen.main.scale
        )
        self.OframeSize = pixelSize

        setupPixelBufferPool(size: pixelSize)

        self.frameCount = 0
        currentFPS = keepaliveFPS

        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        self.displayLayer = layer

        self.pipController = AVPictureInPictureController(
            contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self.dummyDelegate)
        )
        self.pipController?.requiresLinearPlayback = false
        self.pipController?.setValue(1, forKey: "controlsStyle")
        self.pipController?.delegate = self

        self.attachToForegroundWindow {
            PIPLogTo("Keepalive PiP started")
            Task { @MainActor in
                self.startRenderTimer()
            }
        }
    }
    // MARK: - Attach displayLayer
    private func attachToForegroundWindow(completion: @escaping () -> Void) {

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

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
        DispatchQueue.main.async {
            guard let pip = self.pipController, pip.isPictureInPicturePossible else { return }
            pip.startPictureInPicture()
            self.isPiPActive = true
            PIPLogTo("PiP started successfully")
        }
    }

    // MARK: - Render Timer
    private func startRenderTimer() {
        renderCancelled = false
        scheduleNextRender()
    }

    private func scheduleNextRender() {
        guard !renderCancelled else { return }
        let interval = 1.0 / max(currentFPS, 1)
        renderQueue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self = self, !self.renderCancelled else { return }
            Task { @MainActor in
                let didWork = await self.renderIncremental()
                if didWork {
                    self.lastActiveRenderTime = CACurrentMediaTime()
                }
                self.scheduleNextRender()
            }
        }
    }

    private func rescheduleRenderTimer(fps: Double) {
    }

    private func cancelRenderTimer() {
        renderCancelled = true
        renderTimer?.cancel()
        renderTimer = nil
    }

    func cleanupMessageslayer() {
        messagesLayer?.canncel()
        messagesLayer = nil
    }

    // MARK: - Stop PiP
    func stopPiP() {
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

        cleanupMessageslayer()

        if !(userDefaults?.bool(forKey: "TTSEnabled") ?? false) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Incremental Render
    @MainActor
    func renderIncremental() async -> Bool {

        guard let displayLayer = displayLayer else {
            ensureDisplayLayerAttached()
            return false
        }

        guard displayLayer.isReadyForMoreMediaData else {
            decayFPSIfNeeded()
            return false
        }

        let wasAnimating = messagesLayer?.tickAnimation() == true
        if wasAnimating {
            requestAnimationFPS()
        }

        let now = CACurrentMediaTime()
        let periodicRedraw = !needsRedraw && !wasAnimating && (now - lastPeriodicRedraw) >= periodicRedrawInterval
        if periodicRedraw { needsRedraw = true }

        guard needsRedraw || wasAnimating else {
            decayFPSIfNeeded()
            return false
        }
        needsRedraw = false
        if periodicRedraw { lastPeriodicRedraw = now }

        var pixelBuffer: CVPixelBuffer?

        pixelBuffer = renderIfNeeded()

        guard let pixelBuffer = pixelBuffer else {
            decayFPSIfNeeded()
            return false
        }

        if self.basePTS == nil { self.basePTS = CACurrentMediaTime() }

        guard let sampleBuffer = createSampleBuffer(from: pixelBuffer) else {
            decayFPSIfNeeded()
            return false
        }

        displayLayer.enqueue(sampleBuffer)
        self.frameCount += 1

        if !self.isPiPActive && self.frameCount >= self.pipStartThreshold {
            self.safeTryStartPiP()
        }

        lastRenderTime = CACurrentMediaTime()

        decayFPSIfNeeded()

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
        guard !isPiPActive else { return }
        cancelRenderTimer()
        pixelBufferPool = nil
        cachedFormatDescription = nil
        cachedFormatSize = .zero
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
    private var isPiPActive = false
    private let pipStartThreshold: Int64 = 3
    private var frameSize: CGSize = CGSize(width: 300, height: 200)

    private let playbackDelegate = DummyPlaybackDelegate()

    // MARK: - Audio
    func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .allowAirPlay])
            try session.setActive(true)
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
        isPiPActive = false

        if !(userDefaults?.bool(forKey: "TTSEnabled") ?? false) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
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
            guard let self = self else { return }

            print("[R]status:", displayLayer.status.rawValue)
            print("ready:", displayLayer.isReadyForMoreMediaData)
            print("pip active:", pipController?.isPictureInPictureActive as Any)

            if displayLayer.isReadyForMoreMediaData {
                displayLayer.enqueue(sampleBuffer)
                self.frameCount += 1
                logTo("FrameC:\(frameCount)")

                if !self.isPiPActive && self.frameCount >= self.pipStartThreshold {
                    self.pipController?.startPictureInPicture()
                    self.isPiPActive = true
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
