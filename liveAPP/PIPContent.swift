//
//  PIPContent.swift
//  liveAPP
//
//  Created by user on 2025/10/18.
//

import SwiftUI
import UIKit
import AVFoundation
import Foundation



struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let user: String
    let msg: String
    let img: String?
    let giftImg: String?

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
            return lhs.id == rhs.id
        }


}




// MARK: - Cache
private var cache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 20
    cache.totalCostLimit = 20 * 1024 * 1024
    return cache
}()


actor PiPImageCache {

    static let shared = PiPImageCache()

    private static let maxConcurrentDownloads = 5

    // 共用 session：真實 UA + Accept、明確 timeout、HTTP cache、waitsForConnectivity。
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": PiPImageCache.makeUserAgent(),
            "Accept": "image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8"
        ]
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = URLCache(
            memoryCapacity: 20 * 1024 * 1024,
            diskCapacity: 100 * 1024 * 1024,
            diskPath: "PIPImageCache"
        )
        return URLSession(configuration: config)
    }()

    // 真實 Safari UA 樣板：只替換會變動的部分（裝置型號 + OS 版本 + Safari version），
    // 固定段（AppleWebKit / Mobile / Safari build）來自實際抓取的 Safari UA：
    //   Mozilla/5.0 (iPad; CPU OS 18_7 like Mac OS X) AppleWebKit/605.1.15
    //   (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1
    // 注意：Version token 目前跟隨 OS 版本（ProcessInfo），
    // 但真實 Safari 的 Version（如 27.0）從 iOS 18 起與 OS 脫鉤，ProcessInfo 給不出。
    private static func makeUserAgent() -> String {
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
        let device = isIPad ? "iPad" : "iPhone"
        let cpuToken = isIPad ? "CPU OS" : "CPU iPhone OS"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion)_\(os.minorVersion)"
        let safariVersion = "\(os.majorVersion).\(os.minorVersion)"
        return "Mozilla/5.0 (\(device); \(cpuToken) \(osVersion) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Mobile/15E148 Safari/604.1"
    }

    private var inFlightTasks: [String: Task<UIImage?, Never>] = [:]
    private var pendingCallbacks: [String: [(UIImage?) -> Void]] = [:]

    private var currentDownloads = 0
    private var waitingQueue: [String] = []

    private init() {
    }

    func loadImage(urlString: String, completion: @escaping (UIImage?) -> Void) async {
        if let img = cache.object(forKey: urlString as NSString) {
            await MainActor.run {
                completion(img)
            }
            return
        }

        if inFlightTasks[urlString] != nil {
            pendingCallbacks[urlString, default: []].append(completion)
            return
        }

        // 已在 waiting queue（尚未開始下載）→ 只附加 callback，避免重複入隊
        if pendingCallbacks[urlString] != nil {
            pendingCallbacks[urlString]?.append(completion)
            return
        }

        if currentDownloads >= Self.maxConcurrentDownloads {
            waitingQueue.append(urlString)
            pendingCallbacks[urlString] = [completion]
            return
        }

        startDownload(urlString: urlString, completions: [completion])
    }

    private func startDownload(urlString: String, completions: [(UIImage?) -> Void]) {
        currentDownloads += 1
        let task = Task<UIImage?, Never> {
            await self.performDownload(urlString: urlString, completions: completions)
            return nil
        }
        inFlightTasks[urlString] = task
    }

    private func performDownload(
        urlString: String,
        completions: [(UIImage?) -> Void]
    ) async {
        guard let url = URL(string: urlString) else {
            await complete(urlString: urlString, completions: completions, image: nil)
            return
        }

        do {
            let (data, response) = try await Self.session.data(for: URLRequest(url: url))

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                PIPLogTo("[PIPImageCache] HTTP \(status) 拒絕 \(urlString)")
                await complete(urlString: urlString, completions: completions, image: nil)
                return
            }

            let image = UIImage(data: data)
            if let image {
                cache.setObject(image, forKey: urlString as NSString)
            } else {
                PIPLogTo("[PIPImageCache] decode 失敗 (HTTP 200) \(urlString)")
            }
            await complete(urlString: urlString, completions: completions, image: image)
        } catch {
            PIPLogTo("[PIPImageCache] 下載失敗: \(error.localizedDescription) \(urlString)")
            await complete(urlString: urlString, completions: completions, image: nil)
        }
    }

    private func complete(
        urlString: String,
        completions: [(UIImage?) -> Void],
        image: UIImage?
    ) async {
        let callbacks = pendingCallbacks.removeValue(forKey: urlString) ?? []
        await MainActor.run {
            for cb in completions {
                cb(image)
            }
            for cb in callbacks {
                cb(image)
            }
        }
        finishDownload(urlString: urlString)
    }

    private func finishDownload(urlString: String) {
        inFlightTasks[urlString] = nil
        currentDownloads = max(0, currentDownloads - 1)
        startNextIfPossible()
    }

    // 真正的 FIFO：slot 空出時從 waitingQueue pop 下一個，取代原本的 busy-wait
    private func startNextIfPossible() {
        while currentDownloads < Self.maxConcurrentDownloads, !waitingQueue.isEmpty {
            let nextURL = waitingQueue.removeFirst()
            let callbacks = pendingCallbacks.removeValue(forKey: nextURL) ?? []
            guard !callbacks.isEmpty else { continue }
            startDownload(urlString: nextURL, completions: callbacks)
        }
    }

    func clear() {
        cache.removeAllObjects()
        inFlightTasks.values.forEach { $0.cancel() }
        inFlightTasks.removeAll()
        pendingCallbacks.removeAll()
        waitingQueue.removeAll()
        currentDownloads = 0
    }
}



enum MessageType {
    case primary
    case secondary
}



// MARK: Message Model
final class MessageLayerTuple:Equatable {


    var type: MessageType
    let insertionIndex: Int

    var initialStartY: CGFloat = 0

    var hasAvatarSlot: Bool = false

    var isNew: Bool = false
    var startY: CGFloat = 0
    var targetY: CGFloat = 0
    var height: CGFloat = 0

    var alpha: CGFloat = 1.0
    var font: UIFont?

    var name: CATextLayer?
    var message: CATextLayer?
    var avatar: CALayer?
    var gift: CALayer?

    var avatarSize: CGFloat?
    var giftSize: CGFloat?

    var avatarImage:CGSize?
    var giftImage:CGSize?



    var leftPadding: CGFloat = 8
    var textX: CGFloat = 0
    var adjustedY:CGFloat = 0


    var isFadingOut: Bool = false
    var isMoving:Bool = false

    var parentMessageID: UUID? = nil
    var segmentIndex: Int = 0

    var didResolveSize: Bool = false

    var verticalSpacing: CGFloat = 4
    var horizontalSpacing: CGFloat = 4

    var inlineEmojis: [CALayer] = []
    var inlineEmojiSizes: [CGSize] = []
    var inlineEmojiCharIndices: [Int] = []


    var overflowHeight: CGFloat?

    var cachedNameSize: CGSize = .zero
    var cachedMessageSize: CGSize = .zero

    var cachedGiftOffsetX: CGFloat = 0
    var cachedGiftOffsetY: CGFloat = 0

    var lastLineText: String?



    static func == (lhs: MessageLayerTuple, rhs: MessageLayerTuple) -> Bool {
        return lhs === rhs
    }


    init(
        avatar: CALayer?,
        name: CATextLayer?,
        message: CATextLayer?,
        gift: CALayer?,
        type:MessageType = .primary,
        insertionIndex:Int = 0
    ) {
        self.avatar = avatar
        self.name = name
        self.message = message
        self.gift = gift
        self.type = type
        self.insertionIndex = insertionIndex
    }
}



struct MessageSegmentData {
    let parentID: UUID
    let segmentIndex: Int


    let parentHasAvatar:Bool
    let maxMessageWidth:CGFloat

    let type: MessageType
    let user: String
    let message: String

    let showAvatar: Bool
    let showName: Bool
    let showMessage: Bool
    let showGift: Bool

    let avatarURL: String?
    let avatarSizeLocal: CGFloat?

    let giftURL: String?
    let giftSizeLocal:CGFloat?

    let inlineEmojiURLs: [String]
    let inlineEmojiCharIndices: [Int]

    let font:UIFont?

    var verticalSpacing: CGFloat = 4.0
    var horizontalSpacing: CGFloat = 4.0

    let cachedLines: [String]
    let cachedMessageSize: CGSize
    let cachedGiftOffsetX: CGFloat
    let cachedGiftOffsetY: CGFloat


}

final class LayerPool {

    private var textLayers: [CATextLayer] = []
    private var imageLayers: [CALayer] = []

    private let scale = UIScreen.main.scale

    func getTextLayer() -> CATextLayer {
        if let layer = textLayers.popLast() {
            layer.isHidden = false
            return layer
        }

        let layer = CATextLayer()
        layer.contentsScale = scale
        layer.isWrapped = true
        layer.alignmentMode = .left
        return layer
    }

    func recycleTextLayer(_ layer: CATextLayer) {
        layer.removeAllAnimations()
        layer.string = nil
        layer.opacity = 1
        layer.frame = .zero
        layer.isHidden = false
        layer.isWrapped = true
        layer.truncationMode = .none
        layer.alignmentMode = .left
        layer.removeFromSuperlayer()
        textLayers.append(layer)
    }

    func getImageLayer() -> CALayer {
        if let layer = imageLayers.popLast() {
            layer.isHidden = false
            return layer
        }

        let layer = CALayer()
        layer.contentsScale = scale
        return layer
    }

    func recycleImageLayer(_ layer: CALayer) {
        layer.removeAllAnimations()
        layer.contents = nil
        layer.opacity = 1
        layer.frame = .zero
        layer.cornerRadius = 0
        layer.masksToBounds = false
        layer.contentsGravity = .resize
        layer.isHidden = false
        layer.removeFromSuperlayer()
        imageLayers.append(layer)
    }
}




// MARK: - PIP 訊息組（PiP 專用動畫版）
final class PIPServiceMessages {

    private var insertionCounter: Int = 0
    var verboseFrameLog = false
    var verboseLayoutLog = false

    func updateLogSettings(verboseFrame: Bool? = nil, verboseLayout: Bool? = nil) {
        
        if let verboseFrame = verboseFrame {
            self.verboseFrameLog = verboseFrame
        }
        if let verboseLayout = verboseLayout {
            self.verboseLayoutLog = verboseLayout
        }
    }

    enum AnimationPhase {
        case moving
        case fading
        case waitFading
        case pending

        case idle
    }

    private var phase: AnimationPhase = .idle

    private var animatingGroups: [[MessageLayerTuple]] = []

    var containerHeight: CGFloat { container.bounds.height }
    var scrollSpeed: CGFloat

    var fadeOutThreshold: CGFloat {
        return container.bounds.height - (stackedMessages.reduce(0) { $0 + $1.height } - container.bounds.height)
    }

    private var lastFadeTriggerTime: CFTimeInterval = 0
    private var lastMoveTriggerTime: CFTimeInterval = 0


    var fadeInterval: CFTimeInterval = LPConfig.shared.MessageFadeTime

    private var fadingParentID: UUID?

    func groupLeader(_ msg: MessageLayerTuple) -> MessageLayerTuple? {
        stackedMessages
            .filter { $0.parentMessageID == msg.parentMessageID }
            .min(by: { $0.segmentIndex < $1.segmentIndex })
    }


    let container = CALayer()
    private let layerPool = LayerPool()

    var stackedMessages: [MessageLayerTuple] = []

    private var bottomMessage: MessageLayerTuple?




    private var animatingMessages: [MessageLayerTuple] = []

    var font: UIFont = .systemFont(ofSize: 16)
    var lineHeight: CGFloat = 20
    var avatarSize: CGFloat = 28
    var giftSize: CGFloat = 28

    var adOverlayOffset: CGFloat = 0

    var topMargin: CGFloat {
        max(65, container.bounds.height * 0.18) + adOverlayOffset
    }

    func setAdOverlayOffset(_ offset: CGFloat) {
        adOverlayOffset = offset
        // 直接重新排版不觸發動畫，避免 overlay 顯示與訊息移動重疊
        let _ = relayoutTargetsOnly(updateTargetY: true, changeSY: true)
        for msg in stackedMessages where msg.alpha > 0 {
            msg.startY = msg.targetY
            layout(msg: msg, y: msg.targetY)
        }
    }


    private var lastDirtyTime: CFTimeInterval = 0

    private var needsRelayoutAfterRemoval = false


    private var fadeCandidate: MessageLayerTuple?

    let bottomPadding: CGFloat = 4

    private var safeCanncel: Bool = false

    deinit {

        logTo("Deinit OK")

    }

    func canncel() {
        safeCanncel = true
        phase = .idle
        fadeCandidate = nil
        pendingSegments.removeAll()
        animatingMessages.removeAll()
        animatingGroups.removeAll()
        while let msg = stackedMessages.first {
            removeMessage(msg)
        }
        logTo("已取消使用")

    }



    private var hasLaidOutOnce = false
    var isAnimating: Bool {
        phase != .idle
    }


    init(size: CGSize,scrollSpeed:CGFloat = 0.2) {
        container.frame = CGRect(origin: .zero, size: size)
        container.masksToBounds = true

        self.scrollSpeed = scrollSpeed

        logTo("PIPServiceMessages initialized with container size: \(size)")
        
        updateLogSettings(
            verboseFrame: userDefaults?.bool(forKey: "PIPLayout") ?? false,
            verboseLayout: userDefaults?.bool(forKey: "PIPFrameLog") ?? false
        )

    }


    private func collectMovingMessages() {

        animatingMessages.removeAll()

        for group in animatingGroups {
            for msg in group {
                if abs(msg.startY - msg.targetY) > snapThreshold {
                    animatingMessages.append(msg)
                }
            }
        }
    }

    func fixMoving() {
        let moving = animatingMessages.filter {
            abs($0.startY - $0.targetY) >= snapThreshold
        }

        guard !moving.isEmpty else {
            return
        }

        let grouped = Dictionary(grouping: moving, by: { $0.parentMessageID })
            .values
            .map { $0.sorted { $0.segmentIndex < $1.segmentIndex } }

        let orderedGroups = grouped.sorted { group1, group2 in
            (group1.first?.targetY ?? 0) < (group2.first?.targetY ?? 0)
        }

        animatingGroups = orderedGroups

    }

    private func relayoutTargetsOnly(updateTargetY: Bool = true,changeSY:Bool=true) -> [MessageLayerTuple] {


        let relayoutMessages = stackedMessages
            .filter {
                $0.alpha > 0 &&
                $0.didResolveSize
            }

        var yCursor = topMargin

        if changeSY {
            for msg in relayoutMessages where msg.startY <= 0 {
                msg.startY = containerHeight
            }
        }

        let orderedMessages = relayoutMessages.sorted { lhs, rhs in
            if lhs.parentMessageID == rhs.parentMessageID {
                return lhs.segmentIndex < rhs.segmentIndex
            }

            return lhs.insertionIndex < rhs.insertionIndex
        }


        for (index,msg) in orderedMessages.enumerated() {
            if updateTargetY {
                msg.targetY = yCursor

            }


            if verboseLayoutLog {
                PIPChatLog(
                    "index:\(index) Name:\(String(describing: msg.name?.string))\nMES:\(String(describing: msg.message?.string))\n\(msg.startY)->\(msg.targetY)\nUID:\(String(describing: msg.parentMessageID))"
                )
            }

            if msg.name == nil {
                yCursor += msg.height

            } else {
                yCursor += msg.height + msg.verticalSpacing
            }
        }




        if !hasLaidOutOnce {
            hasLaidOutOnce = true
            PIPChatLog("First layout baseline established")
        }

        return orderedMessages

    }





    func breakMessageIntoLines(_ text: String, font: UIFont, maxWidth: CGFloat) -> ([String],[CTLine]) {

        let attr = NSAttributedString(string: text, attributes: [.font: font])

        let framesetter = CTFramesetterCreateWithAttributedString(attr)

        let path = CGPath(rect: CGRect(
            x: 0,
            y: 0,
            width: maxWidth,
            height: .greatestFiniteMagnitude
        ), transform: nil)

        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attr.length),
            path,
            nil
        )

        let lines = CTFrameGetLines(frame) as! [CTLine]

        var result: [String] = []

        for line in lines {
            let range = CTLineGetStringRange(line)
            let nsRange = NSRange(location: range.location, length: range.length)
            let substring = (text as NSString).substring(with: nsRange)
            result.append(substring)
        }

        return (result,lines)
    }

    private func calculateGiftOffset(lines: [CTLine], messageSize: CGSize, giftSize: CGFloat) -> (CGFloat, CGFloat) {
        guard let lastLine = lines.last else {
            return (0, (messageSize.height - giftSize) / 2)
        }

        let lastLineWidth = CGFloat(CTLineGetTypographicBounds(lastLine, nil, nil, nil))

        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(CTFramesetterCreateFrame(
            CTFramesetterCreateWithAttributedString(NSAttributedString(string: "")),
            CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(origin: .zero, size: messageSize), transform: nil),
            nil
        ), CFRangeMake(0, 0), &origins)

        let lastLineOriginY = origins.last?.y ?? 0

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        CTLineGetTypographicBounds(lastLine, &ascent, &descent, &leading)

        let visualOffset: CGFloat = 2.0

        let giftX = lastLineWidth + 2.0
        let giftY = messageSize.height - lastLineOriginY - ascent / 2 - giftSize / 2 - visualOffset

        return (giftX, giftY)
    }


    private func splitLongMessage(
        type:MessageType,
        user: String,
        message: String,
        imgURL: String?,
        giftURL: String?,
        emojiURLs: [String] = [],
        emojiPositions: [Int] = [],
        font: UIFont,
        avatarSizeLocal: CGFloat,
        giftSizeLocal: CGFloat,
        vSpacing:CGFloat = 4.0,
        hSpacing:CGFloat = 4.0
    ) -> [MessageSegmentData] {


        var result: [MessageSegmentData] = []

        var seg = 0
        
        let parentID = UUID()


        let maxMessageWidth = container.bounds.width
            - vSpacing * 2
            - avatarSizeLocal
            - hSpacing
            - giftSizeLocal

        let maxNameWidth = container.bounds.width
            - hSpacing * 2
            - avatarSizeLocal

        let (nameLines,nameCTLine) = breakMessageIntoLines(
            user,
            font: font,
            maxWidth: maxNameWidth
        )


        for (index, line) in nameLines.enumerated() {

            let isFirst = index == 0

            let attr = NSAttributedString(string: line,
                                          attributes: [.font: font]
            )

            let framesetter = CTFramesetterCreateWithAttributedString(attr)

            let messageSize =
                CTFramesetterSuggestFrameSizeWithConstraints(
                    framesetter,
                    CFRangeMake(0, attr.length),
                    nil,
                    CGSize(width: maxNameWidth, height: .greatestFiniteMagnitude),
                    nil
                )

            let (giftX, giftY) = calculateGiftOffset(
                lines: nameCTLine,
                messageSize: messageSize, giftSize: giftSizeLocal
            )



            let data = MessageSegmentData(
                    parentID: parentID,
                    segmentIndex: seg, parentHasAvatar: imgURL != nil, maxMessageWidth:  maxMessageWidth,
                    type: type,
                    user: line,
                    message: "",
                    showAvatar: isFirst,
                    showName: true,
                    showMessage: false,
                    showGift: false,
                    avatarURL: isFirst ? imgURL : nil,
                    avatarSizeLocal: avatarSizeLocal,
                    giftURL: nil,
                    giftSizeLocal:giftSizeLocal,
                    inlineEmojiURLs: [],
                    inlineEmojiCharIndices: [],
                    font:font,
                    verticalSpacing:vSpacing,
                    horizontalSpacing: hSpacing,
                    cachedLines: nameLines,
                    cachedMessageSize: messageSize,
                    cachedGiftOffsetX: giftX,
                    cachedGiftOffsetY: giftY

                )


            seg += 1


            PIPChatLog(
                "Split segment \(index): text='\(line)'"
            )


            result.append(data)
        }


        let (messageLines,msgCTLine) = breakMessageIntoLines(
            message,
            font: font, maxWidth: maxMessageWidth
        )

        var lineStartIndex = 0

        for (index, line) in messageLines.enumerated() {
            let lineLen = line.count
            var lineEmojiURLs: [String] = []
            var lineEmojiIndices: [Int] = []
            for (ei, pos) in emojiPositions.enumerated() {
                let localPos = pos - lineStartIndex
                if localPos >= 0 && localPos < lineLen && ei < emojiURLs.count {
                    lineEmojiURLs.append(emojiURLs[ei])
                    lineEmojiIndices.append(localPos)
                }
            }
            lineStartIndex += lineLen

            let isLast = index == messageLines.count - 1

            let attr = NSAttributedString(string: line,
                                          attributes: [.font: font]
            )

            let framesetter = CTFramesetterCreateWithAttributedString(attr)

            let messageSize =
                CTFramesetterSuggestFrameSizeWithConstraints(
                    framesetter,
                    CFRangeMake(0, attr.length),
                    nil,
                    CGSize(width: maxMessageWidth, height: .greatestFiniteMagnitude),
                    nil
                )

            let (giftX, giftY) = calculateGiftOffset(
                lines: msgCTLine,
                messageSize: messageSize, giftSize: giftSizeLocal
            )


            let data = MessageSegmentData(
                    parentID: parentID,
                    segmentIndex: seg, parentHasAvatar: imgURL != nil, maxMessageWidth:  maxMessageWidth,
                    type: type,
                    user: "",
                    message: line,
                    showAvatar: false,
                    showName: false,
                    showMessage: true,
                    showGift: isLast,
                    avatarURL: nil,
                    avatarSizeLocal: avatarSizeLocal,
                    giftURL: isLast ? giftURL : nil,
                    giftSizeLocal: giftSizeLocal,
                    inlineEmojiURLs: lineEmojiURLs,
                    inlineEmojiCharIndices: lineEmojiIndices,
                    font: font,
                    cachedLines: messageLines,
                    cachedMessageSize: messageSize,
                    cachedGiftOffsetX: giftX,
                    cachedGiftOffsetY: giftY
                )



            seg += 1


            PIPChatLog(
                "Split segment \(index): text='\(line)'"
            )


            result.append(data)
        }

        return result
    }



    func buildMessageTuple(
        type:MessageType = .primary,
        user: String = "",
        message: String = "",
        img: UIImage?,
        giftImg: UIImage?,
        showAvatar: Bool,
        showName: Bool,
        showMessage:Bool = true,
        showGift:Bool = false,
        font: UIFont,
        avatarSizeLocal: CGFloat,
        giftSizeLocal: CGFloat,
        verticalSpacing:CGFloat = 4,
        horizontalSpacing:CGFloat = 4,
        data: MessageSegmentData


    ) -> MessageLayerTuple {


        var avatarLayer :CALayer?

        if showAvatar {
            let layer = layerPool.getImageLayer()
            layer.contents = img?.cgImage
            layer.contentsGravity = .resizeAspectFill
            layer.frame = CGRect(
                x: horizontalSpacing,
                y: container.bounds.height,
                width: avatarSizeLocal,
                height: avatarSizeLocal
            )

            layer.cornerRadius = avatarSizeLocal / 2
            layer.masksToBounds = true


            container.addSublayer(layer)
            avatarLayer = layer

        }

        var nameLayer: CATextLayer?

        if showName {
            let layer = layerPool.getTextLayer()

            layer.string = NSAttributedString(
                string:user,
                attributes: [
                   .font: font,
                   .foregroundColor: UIColor.white
                ]
            )
            
            
            layer.contentsScale = UIScreen.main.scale
            layer.isWrapped = true
            layer.truncationMode = .none
            layer.alignmentMode = .left

            container.addSublayer(layer)
            nameLayer = layer

        }

        var messageLayer: CATextLayer?

        if showMessage {

            let layer = layerPool.getTextLayer()
            layer.string = NSAttributedString(
                string:message,
                attributes: [
                   .font: font,
                   .foregroundColor: UIColor.white
                ]
            )
            
            layer.contentsScale = UIScreen.main.scale
            layer.isWrapped = true
            layer.truncationMode = .none

            layer.alignmentMode = .left
            container.addSublayer(layer)
            messageLayer = layer
        }

        var giftLayer: CALayer?

        if showGift {
            let layer = layerPool.getImageLayer()
            layer.contents = giftImg?.cgImage
            layer.contentsGravity = .resizeAspect

            container.addSublayer(layer)
            giftLayer = layer
        }

        var emojiLayers: [CALayer] = []

        for _ in data.inlineEmojiURLs {
            let layer = layerPool.getImageLayer()
            layer.contentsGravity = .resizeAspect

            container.addSublayer(layer)
            emojiLayers.append(layer)
        }


        let tuple = MessageLayerTuple(
            avatar: avatarLayer ,
            name: nameLayer ,
            message: messageLayer,
            gift: giftLayer, insertionIndex: insertionCounter
        )

        insertionCounter += 1

        tuple.font = font
        tuple.avatarSize = avatarSizeLocal
        tuple.giftSize = giftSizeLocal
        tuple.inlineEmojis = emojiLayers
        tuple.inlineEmojiSizes = Array(repeating: CGSize(width: giftSizeLocal, height: giftSizeLocal), count: emojiLayers.count)
        tuple.inlineEmojiCharIndices = data.inlineEmojiCharIndices

        tuple.verticalSpacing = verticalSpacing
        tuple.horizontalSpacing = horizontalSpacing
        tuple.isNew = true
        tuple.alpha = 1.0

        tuple.type = type


        tuple.hasAvatarSlot = data.parentHasAvatar


        let avatarSlotWidth =
            data.parentHasAvatar
            ? (avatarSizeLocal + horizontalSpacing)
            : horizontalSpacing

        tuple.textX = avatarSlotWidth



        tuple.cachedNameSize = data.cachedMessageSize

        tuple.cachedMessageSize = data.cachedMessageSize
        tuple.cachedGiftOffsetX = data.cachedGiftOffsetX
        tuple.cachedGiftOffsetY = data.cachedGiftOffsetY



        var textBlockHeight: CGFloat = 0

        if showName && showMessage {
            textBlockHeight += horizontalSpacing
        }
        else if showName {
            textBlockHeight += data.cachedMessageSize.height
        }
        else if showMessage {
            textBlockHeight += data.cachedMessageSize.height
        }



        tuple.height = textBlockHeight

        tuple.startY = containerHeight


        tuple.didResolveSize = true


        return tuple
    }







    static func extractAllImageURLs(from message: String, maxURLs: Int = 20, placeholder: String = "\u{2003}") -> (cleaned: String, imageURLs: [String], imagePositions: [Int]) {
        let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "PNG", "JPG", "JPEG", "GIF", "WEBP"]
        let pattern = "(https?://[^\\s]+\\.(" + imageExtensions.joined(separator: "|") + ")(\\?[^\\s]*)?)"

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (message, [], [])
        }

        let nsRange = NSRange(message.startIndex..., in: message)
        let matches = regex.matches(in: message, range: nsRange)

        var urls: [String] = []
        var positions: [Int] = []
        var parts: [String] = []
        var lastEnd = message.startIndex

        for match in matches {
            guard urls.count < maxURLs else {
                if Range(match.range(at: 1), in: message) != nil {
                    parts.append(String(message[lastEnd...]))
                }
                lastEnd = message.endIndex
                break
            }
            guard let urlRange = Range(match.range(at: 1), in: message) else { continue }

            if lastEnd < urlRange.lowerBound {
                parts.append(String(message[lastEnd..<urlRange.lowerBound]))
            }

            let currentLen = parts.map(\.count).reduce(0, +)
            positions.append(currentLen)
            urls.append(String(message[urlRange]))
            parts.append(placeholder)
            lastEnd = urlRange.upperBound
        }

        if lastEnd < message.endIndex {
            parts.append(String(message[lastEnd...]))
        }

        return (parts.joined(), urls, positions)
    }

    func addMessage(
        user: String,
        message: String,
        imgURL: String? = nil,
        giftURL: String? = nil,
        isMain: Bool = true
    ) {


        let type: MessageType = isMain ? .primary : .secondary

        var fontSize: CGFloat = (
            type == .primary
        ) ? LPConfig.shared.PIPChatFontMainSize : LPConfig.shared.PIPChatFontSecondSize

        if fontSize < 1.0 {
            PIPChatLog("子母窗口fontSize異常需要更新 需要重新設定")
            fontSize = 1.0
        }
        
        let avatarSizeLocal: CGFloat = (
            type == .primary
        ) ? LPConfig.shared.PIPChatFontMainSize : LPConfig.shared.PIPChatFontSecondSize

        let giftSizeLocal: CGFloat = (
            type == .primary
        ) ? LPConfig.shared.PIPChatFontMainSize : LPConfig.shared.PIPChatFontSecondSize


        let font = UIFont.systemFont(ofSize: fontSize)

        let vSpacing = 4.0
        let hSpacing = 16.0



            let (cleanMessage, emojiURLs, emojiPositions) = Self.extractAllImageURLs(from: message)
            let messageToShow = cleanMessage.isEmpty && !emojiURLs.isEmpty ? " " : cleanMessage

            let segments = self.splitLongMessage(
                type: type, user: user,
                message: messageToShow,
                imgURL:imgURL,
                giftURL: giftURL,
                emojiURLs: emojiURLs,
                emojiPositions: emojiPositions,
                font: font,
                avatarSizeLocal: avatarSizeLocal,
                giftSizeLocal: giftSizeLocal,
                vSpacing: vSpacing,
                hSpacing: hSpacing

            )


            pendingSegments.append(contentsOf: segments)
            if pendingSegments.count > 200 {
                pendingSegments.removeFirst(pendingSegments.count - 200)
            }

            populateVisibleMessagesIfNeeded()

            layoutTargetsAndStartAnimation()







    }


    var pendingSegments: [MessageSegmentData] = []

    func currentBottomTargetY() -> CGFloat {
        stackedMessages
            .filter { !$0.isNew }
            .map { $0.targetY + $0.height }
            .max()
        ?? topMargin
    }



    private func segmentHeight(_ data: MessageSegmentData) -> CGFloat {
        if data.showName && data.showMessage {
            return data.horizontalSpacing
        }

        if data.showName || data.showMessage {
            return data.cachedMessageSize.height
        }

        return 0
    }

    private var visibleInsertLimit: CGFloat {
        containerHeight + containerHeight * 0.30
    }

    private func currentVisibleBottom() -> CGFloat {
        var bottom = topMargin

        for msg in stackedMessages where msg.alpha > 0 && !msg.isFadingOut {
            bottom = max(bottom, msg.targetY + msg.height)
        }

        return bottom
    }

    private func contiguousPendingGroupEnd(parentID: UUID) -> Int {
        var end = 0
        while end < pendingSegments.count,
              pendingSegments[end].parentID == parentID {
            end += 1
        }

        return end
    }

    private func fittingPrefixCount(upTo groupEnd: Int, currentBottom: CGFloat) -> (count: Int, bottom: CGFloat) {
        var bottom = currentBottom
        var count = 0

        for index in 0..<groupEnd {
            let data = pendingSegments[index]
            let nextBottom = bottom + segmentHeight(data) + data.verticalSpacing
            if nextBottom <= visibleInsertLimit || count == 0 && stackedMessages.isEmpty {
                count += 1
                bottom = nextBottom
            } else {
                break
            }
        }

        return (count, bottom)
    }

    func populateVisibleMessagesIfNeeded() {
        var visibleBottom = currentVisibleBottom()

        while let first = pendingSegments.first {
            let groupEnd = contiguousPendingGroupEnd(parentID: first.parentID)
            let fitting = fittingPrefixCount(
                upTo: groupEnd,
                currentBottom: visibleBottom
            )

            guard fitting.count > 0 else {
                phase = .moving
                lastMoveTriggerTime = CACurrentMediaTime()
                PIPChatLog("目前空間不足，等待舊訊息淡出後補上長訊息後段")
                break
            }

            let insertSegments = Array(pendingSegments.prefix(fitting.count))
            visibleBottom = fitting.bottom

            var groupMsgs: [MessageLayerTuple] = []
            for data in insertSegments {
                guard let font = data.font,
                    let avatarSize = data.avatarSizeLocal,
                    let giftSize = data.giftSizeLocal else { return }

                let msg = buildMessageTuple(
                    type: data.type,
                    user: data.user,
                    message: data.message,
                    img: nil,
                    giftImg: nil,
                    showAvatar: data.showAvatar,
                    showName: data.showName,
                    showMessage: data.showMessage,
                    showGift: data.showGift,
                    font: font,
                    avatarSizeLocal: avatarSize,
                    giftSizeLocal: giftSize,
                    verticalSpacing: data.verticalSpacing,
                    horizontalSpacing: data.horizontalSpacing,
                    data: data
                )

                msg.parentMessageID = data.parentID
                msg.segmentIndex = data.segmentIndex
                groupMsgs.append(msg)
            }

            pendingSegments.removeFirst(fitting.count)

            for (data, msg) in zip(insertSegments, groupMsgs) where data.avatarURL != nil {
                if let avatarURL = data.avatarURL {
                    Task {
                        await PiPImageCache.shared.loadImage(urlString: avatarURL) { image in
                            msg.avatar?.contents = image?.cgImage
                            msg.avatarImage = image?.size
                        }
                    }
                }
            }

            for (data, msg) in zip(insertSegments, groupMsgs) where data.giftURL != nil {
                if let giftURL = data.giftURL {
                    Task {
                        await PiPImageCache.shared.loadImage(urlString: giftURL) { image in
                            msg.gift?.contents = image?.cgImage
                            msg.giftImage = image?.size
                        }
                    }
                }
            }

            for (data, msg) in zip(insertSegments, groupMsgs) where !data.inlineEmojiURLs.isEmpty {
                for (idx, emojiURL) in data.inlineEmojiURLs.enumerated() {
                    Task { [idx, msg] in
                        await PiPImageCache.shared.loadImage(urlString: emojiURL) { [weak msg] image in
                            guard let msg = msg, idx < msg.inlineEmojis.count else { return }
                            msg.inlineEmojis[idx].contents = image?.cgImage
                            let newSize: CGSize
                            if let imgSize = image?.size {
                                let maxSize = msg.giftSize ?? self.giftSize
                                let scale = min(maxSize / imgSize.width, maxSize / imgSize.height)
                                newSize = CGSize(
                                    width: imgSize.width * scale,
                                    height: imgSize.height * scale
                                )
                            } else {
                                newSize = CGSize(width: self.giftSize, height: self.giftSize)
                            }
                            msg.inlineEmojiSizes[idx] = newSize
                            let charIndex = idx < msg.inlineEmojiCharIndices.count ? msg.inlineEmojiCharIndices[idx] : 0
                            guard let messageLayer = msg.message, let font = msg.font else { return }
                            let text: String
                            if let attrStr = messageLayer.string as? NSAttributedString {
                                text = attrStr.string
                            } else {
                                text = messageLayer.string as? String ?? ""
                            }
                            let attrLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                            let messageFrame = messageLayer.frame
                            let baseX = messageFrame.origin.x + CTLineGetOffsetForStringIndex(attrLine, charIndex, nil)
                            let emojiY = messageFrame.midY - newSize.height / 2
                            msg.inlineEmojis[idx].frame = CGRect(
                                x: baseX, y: emojiY,
                                width: newSize.width, height: newSize.height
                            )
                        }
                    }
                }
            }


            stackedMessages.append(contentsOf: groupMsgs)



        }
    }




    func IshasOverFlow() -> Bool {


        let bottomY  = stackedMessages
               .filter({ $0.alpha > 0 })
               .map { $0.targetY + $0.height + $0.verticalSpacing }
               .max() ?? topMargin




        let conSize = containerHeight * 0.90 - bottomPadding
        PIPChatLog("MaxBottom:\(bottomY) Container:\(conSize)")
        return bottomY  > conSize


    }



    let snapThreshold: CGFloat = 0.2

    func layoutTargetsAndStartAnimation() {

        _ = relayoutTargetsOnly(updateTargetY: true)

        rebuildAnimatingGroups()
        fixMoving()

        phase = .moving
        lastMoveTriggerTime = CACurrentMediaTime()

        for msg in stackedMessages where abs(msg.startY - msg.targetY) >= snapThreshold {
            msg.initialStartY = msg.startY
        }

        collectMovingMessages()

        PIPService.shared.requestAnimationFPS()
        PIPService.shared.isAnimatingMessages = true

    }





    func isHasFade(_ parentID: UUID?) -> Bool {

        if let parentID {
            return stackedMessages.contains {
                $0.parentMessageID == parentID
            }
        }
        return false
    }


    func isGroupMoving(_ parentID:UUID?) -> Bool {
        if let parentID {
                return stackedMessages.contains {
                $0.parentMessageID == parentID &&
                abs($0.startY - $0.targetY) >= snapThreshold
            }
        }
        return false
    }







    private func rebuildAnimatingGroups() {
        let movingMessages = stackedMessages
            .filter { $0.alpha > 0 && abs($0.startY - $0.targetY) >= snapThreshold }

        let ordered = movingMessages.sorted {
            if $0.parentMessageID == $1.parentMessageID {
                return $0.segmentIndex < $1.segmentIndex
            }
            return $0.insertionIndex < $1.insertionIndex
        }

        let keyedMessages = ordered.compactMap { msg -> (UUID, MessageLayerTuple)? in
            guard let parentID = msg.parentMessageID else { return nil }
            return (parentID, msg)
        }

        animatingGroups = Dictionary(grouping: keyedMessages, by: { $0.0 })
            .values
            .map { group in
                group
                    .map { $0.1 }
                    .sorted { $0.segmentIndex < $1.segmentIndex }
            }

        for msg in movingMessages {
            if !animatingMessages.contains(msg) {
                animatingMessages.append(msg)
            }
        }
    }



    func animateMoveIfNeeded() {

        let moving = animatingGroups

        guard !moving.isEmpty else {
            onMoveFinished()
            return
        }



        let now = CACurrentMediaTime()
        let elapsed = now - lastMoveTriggerTime
        lastMoveTriggerTime = now

        var anyStillMoving = false

        
        for group in moving {
            guard let firstMsg = group.first else { continue }
            let distance = abs(firstMsg.targetY - firstMsg.startY)
            let moveDuration = max(0.15, min(0.45, distance / 120.0))
            let moveStep = min(elapsed / moveDuration, 1)

            var groupMoving = false

            for msg in group {

                if abs(msg.startY - msg.targetY) >= snapThreshold {

                    let newY = msg.startY + (msg.targetY - msg.startY) * moveStep
                    msg.isNew = false
                    msg.startY = newY

                    self.layout(msg: msg, y: newY)

                    groupMoving = true
                }

            }

            if groupMoving {
                anyStillMoving = true
            }


        }


        fixMoving()

        self.animatingMessages.removeAll {
            abs($0.startY - $0.targetY) < self.snapThreshold

        }
        

        if !anyStillMoving {
            onMoveFinished()
        }


    }

    private func onMoveFinished() {

        PIPChatLog("MovingOK")

        populateVisibleMessagesIfNeeded()
        layoutTargetsAndStartAnimation()


        let moving = stackedMessages.filter {
            abs($0.startY - $0.targetY) < snapThreshold
        }

        moving.forEach {
            $0.isNew = false
        }

        if IshasOverFlow() {
            prepareFade()
        } else {
            phase = pendingSegments.isEmpty ? .idle : .pending
            if phase == .idle {
                stopAnimation()
            }
        }
    }



    private func findFadeCandidate() -> MessageLayerTuple? {

        let leaders = stackedMessages
            .filter { msg in
                msg.alpha > 0 &&
                !msg.isNew &&
                !msg.isFadingOut &&
                abs(msg.startY - msg.targetY) < snapThreshold
            }

        guard !leaders.isEmpty else { return nil }

        let candidate = leaders.min(by: {
            $0.targetY < $1.targetY
        })

        return candidate
    }

    private func prepareFade() {
        guard fadeCandidate == nil else {
                phase = .fading
                return
            }

        let now = CACurrentMediaTime()

        if now - lastFadeTriggerTime < fadeInterval {
            phase = .waitFading
            PIPChatLog("等待中 Fade Now: \(now) lastFade:\(lastFadeTriggerTime) FadeInterval:\(fadeInterval) ")

        } else {


            isWaitFade = false

            phase = .fading
            

            fadeCandidate = findFadeCandidate()
            lastFadeTriggerTime = now




        }

    }

    private func stepFade() {
        guard let msg = fadeCandidate else {
            phase = .waitFading
            return
        }


        if let msg = fadeCandidate {
            
                startFadeAnimation(for: msg)
            
        }


        if msg.alpha > 0 {
            return
        }

        removeMessage(msg)
        fadeCandidate = nil

        _ = relayoutTargetsOnly(updateTargetY: true, changeSY: false)

        rebuildAnimatingGroups()
        fixMoving()


        phase = .moving
        lastMoveTriggerTime = CACurrentMediaTime()



    }

    func removeMessage(_ msg:MessageLayerTuple){

        if let avatar = msg.avatar {
            layerPool.recycleImageLayer(avatar)
            msg.avatar = nil
        }
        if let name = msg.name {
            layerPool.recycleTextLayer(name)
            msg.name = nil
        }
        if let message = msg.message {
            layerPool.recycleTextLayer(message)
            msg.message = nil
        }
        if let gift = msg.gift {
            layerPool.recycleImageLayer(gift)
            msg.gift = nil
        }
        for emoji in msg.inlineEmojis {
            layerPool.recycleImageLayer(emoji)
        }
        msg.inlineEmojis.removeAll()
        msg.inlineEmojiSizes.removeAll()

        msg.isFadingOut = false



        if let idx = stackedMessages.firstIndex(where: { $0 ===  msg }) {
            stackedMessages.remove(at: idx)
        }

        animatingMessages.removeAll { $0 ===  msg }
        animatingMessages.removeAll { $0.alpha <= 0 }

        populateVisibleMessagesIfNeeded()
        layoutTargetsAndStartAnimation()

    }


    func clearAllMessages() {
        pendingSegments.removeAll()
        stackedMessages.removeAll()
        animatingMessages.removeAll()
        container.sublayers?.forEach { $0.removeFromSuperlayer() }
        stopAnimation()
    }

    private func stopAnimation() {

        phase = .idle

        Task { @MainActor in
            PIPService.shared.isAnimatingMessages = false
        }

    }
    
    var isWaitFade = false
    func waitFade() {
        
        guard !isWaitFade else { return }

        isWaitFade = true
        PIPService.shared.requestAnimationFPS()

    }

    func reloadPending() {
        guard pendingSegments.count > 0 else {
            phase = .moving
            lastMoveTriggerTime = CACurrentMediaTime()

            PIPChatLog("待處理清單已清理完! :\(pendingSegments.count)")
            return

        }

        _ = relayoutTargetsOnly(updateTargetY: true)
        populateVisibleMessagesIfNeeded()
    }


    private func startFadeAnimation(for msg: MessageLayerTuple) {

        let fadeDuration: CGFloat = LPConfig.shared.FadeAlpha

        let now = CACurrentMediaTime()
        let elapsed = now - lastFadeTriggerTime
        let fadeStep = min(elapsed / fadeDuration, 1)

        lastFadeTriggerTime = now

        msg.isFadingOut = true

        if msg.alpha > 0 {
            let nextAlpha = max(0, msg.alpha - fadeStep)
            let layerOpacity = Float(nextAlpha)
            msg.alpha = nextAlpha

            if let avatar = msg.avatar {
                avatar.opacity = layerOpacity
            }
            if let name = msg.name {
                name.opacity = layerOpacity
            }
            if let MSG = msg.message {
                MSG.opacity = layerOpacity
            }
            if let gift = msg.gift {
                gift.opacity = layerOpacity
            }
            for emoji in msg.inlineEmojis {
                emoji.opacity = layerOpacity
            }

        }


    }


    func tickAnimation() -> Bool {
        guard !safeCanncel else {
            stopAnimation()
            return false
        }

        if verboseFrameLog {
            PIPChatLog(
                "tick | anim:\(animatingMessages.count) 待處理:\(pendingSegments.count) 容器數量:\(stackedMessages.count) - \(phase)"
            )
        }

        switch phase {
        case .moving:
            animateMoveIfNeeded()
            return isAnimating

        case .fading:
            stepFade()
            return isAnimating

        case .idle:
            stopAnimation()
            return false

        case .waitFading:
            waitFade()
            prepareFade()
            return isAnimating

        case .pending:
            reloadPending()
            return isAnimating
        }
    }


    private func layout(msg: MessageLayerTuple, y: CGFloat,x:CGFloat? = nil) {

        let adjustedY = max(y, topMargin)

        msg.adjustedY = adjustedY

        let avatarSizeLocal = msg.avatarSize ?? self.avatarSize
        let giftSizeLocal = msg.giftSize ?? self.giftSize

        let textX = msg.textX

        msg.avatar?.frame.origin = CGPoint(
            x: textX - avatarSizeLocal,
            y: y
        )



        var cursorY = y

        if let nameLayer = msg.name {
            let size = msg.cachedNameSize

            nameLayer.frame = CGRect(
                x: textX,
                y: cursorY ,
                width: size.width,
                height: size.height
            )



            cursorY += size.height + msg.verticalSpacing

            let textCenterY = nameLayer.frame.origin.y + nameLayer.frame.height / 2
            msg.avatar?.frame.origin.y = textCenterY - avatarSizeLocal / 2

        }



        var offSet = 0.0

        if let message = msg.message {
            let size = msg.cachedMessageSize

            if msg.type == .secondary {
                offSet = msg.horizontalSpacing
            }


            message.frame = CGRect(
                x: textX + offSet,
                y: cursorY,
                width: size.width,
                height: size.height
            )

        }

        if let gift = msg.gift,
           let messageLayer = msg.message {

            let minX = messageLayer.frame.minX
            let minY = messageLayer.frame.minY

            let GiftCX = msg.cachedGiftOffsetX
            let GiftCY = msg.cachedGiftOffsetY



            gift.frame = CGRect(
                x: minX + GiftCX,
                y: minY + GiftCY,
                width: giftSizeLocal,
                height: giftSizeLocal
            )


        }

        // Inline Emoji
        let messageFrame = msg.message?.frame ?? .zero
        let text: String
        if let attrStr = msg.message?.string as? NSAttributedString {
            text = attrStr.string
        } else {
            text = msg.message?.string as? String ?? ""
        }
        let attrLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: msg.font ?? UIFont.systemFont(ofSize: 12)]))

        var lastEmojiMaxX: CGFloat = 0
        var lastCharIndex: Int = -1

        for (idx, emoji) in msg.inlineEmojis.enumerated() {
            let emojiSize = idx < msg.inlineEmojiSizes.count ? msg.inlineEmojiSizes[idx].width : giftSizeLocal

            let charIndex = idx < msg.inlineEmojiCharIndices.count ? msg.inlineEmojiCharIndices[idx] : 0
            let baseX = messageFrame.origin.x + CTLineGetOffsetForStringIndex(attrLine, charIndex, nil)

            let emojiX = (charIndex == lastCharIndex) ? (lastEmojiMaxX + 4) : baseX
            lastEmojiMaxX = emojiX + emojiSize
            lastCharIndex = charIndex

            let emojiY = messageFrame.midY - emojiSize / 2

            emoji.frame = CGRect(
                x: emojiX,
                y: emojiY,
                width: emojiSize,
                height: emojiSize
            )
        }


    }

    private func easeOutCubic(_ t: Double) -> Double {
        1 - pow(1 - t, 3)
    }

}

func PIPChatLog(_ message:String){
    guard LPConfig.shared.PIPChatLog else { return }

    logger.debug("PIPCHAT \(message)")
    sendlog(title:"[PIP_Chat]",message: message)

}

struct DebugImageViewWrapper: UIViewRepresentable {

    let layer: AVSampleBufferDisplayLayer?

    func makeUIView(context: Context) -> UIView {
        let container = UIView()

        if let layer = layer {
                    layer.frame = container.bounds
                    layer.videoGravity = .resizeAspect
                    layer.backgroundColor = #colorLiteral(red: 0.9254902005, green: 0.2352941185, blue: 0.1019607857, alpha: 1)
                    container.layer.addSublayer(layer)
        }


        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {


    }
}

struct PIPView: View {

    @ObservedObject private var pipService = PIPService.shared

    @State private var isTestPiPActive = false

    @State private var manualMessage: String = "test"
    @State private var manualUser: String = "User33"

    var body: some View {
        VStack(spacing: 20) {
            Text("Chat")

            HStack(spacing: 20) {
                VStack(spacing: 10) {
                    Button("[聊天組]啟動 PiP") {
                        let pipSize = CGSize(width: 300, height: 200)
                        PIPService.shared.startPiP(size: pipSize)
                    }
                    .disabled((pipService.isPiPActive && !pipService.isKeepaliveMode) || isTestPiPActive)

                    Button("[保活組]啟動 PiP 保活") {
                        let pipSize = CGSize(width: 300, height: 200)
                        PIPService.shared.startKeepalivePiP(size: pipSize)
                    }
                    .disabled(pipService.isPiPActive || isTestPiPActive)

                    Button("[聊天室]停止 PiP") {
                        PIPService.shared.stopPiP()
                    }
                    .disabled(!pipService.isPiPActive)
                }

                VStack(spacing: 10) {
                    Button("[測試組]啟動 PiP") {
                        PIPTestService.shared.startPiPTest(size: CGSize(width: 300, height: 200))
                        isTestPiPActive = true
                    }
                    .disabled(pipService.isPiPActive || isTestPiPActive)

                    Button("[測試組]停止 PiP") {
                        PIPTestService.shared.stopPiP()
                        isTestPiPActive = false
                    }
                    .disabled(!isTestPiPActive)
                }
            }

            VStack(spacing: 10) {
                TextField("輸入手動用戶名", text: $manualUser)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                TextField("輸入手動訊息", text: $manualMessage)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                Button("新增訊息") {
                    let imgA = "https://img.icons8.com/?size=100&id=12860&format=png&color=000000"
                    let imgG = "https://img.icons8.com/?size=100&id=y5xu7jml0MTU&format=png&color=000000"

                    PIPService.shared
                        .addMessage(
                            user: manualUser,
                            msg: manualMessage,
                            imgURL: imgA,
                            giftURL: imgG
                        )

                    TTSService.shared.speakStreamMessage(
                        user: manualUser,
                        message: manualMessage
                    )

                }

            }



            Button("測試長訊息") {

                let user =  "1阿呵呵呵阿呵呵呵阿呵呵呵阿呵呵呵2阿呵呵呵阿3呵呵呵阿呵呵4呵阿呵呵呵阿呵呵呵阿呵呵呵阿5呵呵呵阿呵呵呵阿呵呵呵阿呵呵呵阿呵呵呵測試5"

                let msg =  "1阿呵呵呵阿呵呵呵2阿呵呵呵阿3呵呵呵阿呵呵呵阿呵呵呵阿呵4呵呵阿呵呵呵阿呵呵呵阿呵呵呵5阿呵呵呵阿呵呵呵阿呵呵呵測試6"
                let img = "https://img.icons8.com/?size=100&id=L8HgZUgz2jWS&format=png&color=000000"

                let gift = "https://img.icons8.com/?size=100&id=tgLepcPbp6mP&format=png&color=000000"

                PIPService.shared
                    .addMessage(user: user, msg: msg,imgURL: img,giftURL: gift)


                TTSService.shared.speakStreamMessage(
                    user: user,
                    message: msg
                )

            }
            Button("TestB") {
                let imgA = "https://img.icons8.com/?size=100&id=12860&format=png&color=000000"
                let imgG = "https://img.icons8.com/?size=100&id=y5xu7jml0MTU&format=png&color=000000"


                let UNAME = "小明3"
                let UMSG = "Hello!"

                PIPService.shared.addMessage(user: UNAME, msg: UMSG, imgURL: imgA, giftURL: imgG)

                TTSService.shared.speakStreamMessage(
                    user: UNAME,
                    message: UMSG
                )

            }

            Button("Test次要訊息") {
                let imgA = "https://img.icons8.com/?size=100&id=12860&format=png&color=000000"
                let imgG = "https://img.icons8.com/?size=100&id=y5xu7jml0MTU&format=png&color=000000"

                let UNAME = "小明2"
                let UMSG = "Hello!"

                PIPService.shared.addMessage(user: UNAME , msg: UMSG , imgURL: imgA, giftURL: imgG, isMain: false)

                TTSService.shared.speakStreamMessage(
                    user: UNAME,
                    message: UMSG,
                    isMain:false
                )

            }

            Button("新增訊息") {

                let UNAME = ""
                let UMSG = "測試訊息圖片"
                let GIFTURL = "https://img.icons8.com/?size=100&id=y5xu7jml0MTU&format=png&color=000000"
                
                PIPService.shared.addMessage(
                    msg: UMSG,
                    imgURL: "https://img.icons8.com/?size=100&id=12860&format=png&color=000000",
                    giftURL: GIFTURL
                )


                TTSService.shared.speakStreamMessage(
                    user: UNAME,
                    message: UMSG
                )

            }

        }
        .padding()
    }
}
