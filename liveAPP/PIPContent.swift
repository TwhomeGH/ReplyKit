//
//  PIPContent.swift
//  liveAPP
//
//  Created by user on 2025/10/18.
//

import SwiftUI
import UIKit

import CoreVideo

import AVFoundation
import AVKit




struct ChatMessage: Identifiable, Equatable {
    let id = UUID()       // 唯一識別符
    let user: String // 粉絲
    let msg: String // 訊息
    let img: String? // 圖片
    let giftImg: String? // 禮物圖片

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
            return lhs.id == rhs.id
        }


}




// MARK: - Cache
private let cache = NSCache<NSString, UIImage>()


actor PiPImageCache {

    static let shared = PiPImageCache()


    // 正在下載中的任務（防止重複下載）
    private var inFlightTasks: [String: Task<UIImage?, Never>] = [:]

    // 併發限制
    private let maxConcurrentDownloads = 5
    private var currentDownloads = 0
    private var waitingQueue: [String] = []

    private init() {
        cache.countLimit = 20
        cache.totalCostLimit = 20 * 1024 * 1024
    }

    // MARK: - Public API（async 版）
    func loadImage(urlString: String, completion: @escaping (UIImage?) -> Void) async {

        // cache hit
        if let img = cache.object(forKey: urlString as NSString) {
            completion(img)
            return
        }

        // 防止重複下載
        if inFlightTasks[urlString] != nil {
            // 可以選擇加入回調列表
            return
        }

        let task = Task<UIImage?, Never> {
            await self.waitForSlot()

            guard let url = URL(string: urlString) else {
                self.finishDownload(urlString: urlString)
                return nil
            }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)

                // ✅ 背景解碼，不 await
                Task.detached(priority: .userInitiated) {
                    if let img = UIImage(data: data) {
                        cache.setObject(img, forKey: urlString as NSString)
                        await MainActor.run {
                            completion(img)
                        }
                    }
                    await self.finishDownload(urlString: urlString)
                }

                return nil

            } catch {

                self.finishDownload(urlString: urlString)

                return nil
            }
        }

        inFlightTasks[urlString] = task
    }

    // MARK: - 併發控制

    private func waitForSlot() async {
        while currentDownloads >= maxConcurrentDownloads {
            await Task.yield()
        }
        currentDownloads += 1
    }

    private func finishDownload(urlString: String) {
        currentDownloads = max(0, currentDownloads - 1)
        inFlightTasks[urlString] = nil
    }
}



enum MessageType {
    case primary
    case secondary
}



final class PixelBufferPool {

    private var pool: CVPixelBufferPool!

    init(size: CGSize) {

        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
        ]

        CVPixelBufferPoolCreate(
            nil,
            poolAttrs as CFDictionary,
            pixelAttrs as CFDictionary,
            &pool
        )
    }

    func makePixelBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer!
    }
}

final class MessageGPURenderer {

    private let device = MTLCreateSystemDefaultDevice()!


    private var ciContext: CIContext
    private var pool: PixelBufferPool?


    init(size: CGSize,ciText:CIContext) {
        ciContext = ciText
        pool = PixelBufferPool(size: size)

    }

    deinit {
        pool = nil
    }



    func render(time:CIImage? = nil,containerSize:CGSize) -> CVPixelBuffer? {

        guard let pixelBuffer = pool?.makePixelBuffer() else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)



        if let time = time {

            ciContext.render(
                time,
                to: pixelBuffer,
                bounds: CGRect(
                    x: 0,
                    y: 0,
                    width: width,
                    height: height)
                ,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )

            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            return pixelBuffer

        }

        // 如果沒有 time，則回傳空透明
        let blank = CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))

        ciContext.render(blank, to: pixelBuffer, bounds: blank.extent, colorSpace: CGColorSpaceCreateDeviceRGB())




        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        return pixelBuffer
    }

}


// MARK: Message Model
final class MessageLayerTuple:Equatable {


    var type: MessageType

    // layout
    var isNew: Bool = false      // 是否新訊息
    var startY: CGFloat = 0      // 動畫起始 y
    var targetY: CGFloat = 0     // 動畫目標 y
    var height: CGFloat = 0      // 訊息總高度

    // 透明度控制，用於漸隱
    var alpha: CGFloat = 1.0

    var resolvedBottomY:CGFloat = 0.0

    let name: CATextLayer?
    let message: CATextLayer?
    // ⚡ 新增支援訊息大小的屬性
    var font: UIFont?             // 訊息字體


    let avatar: CALayer?
    let gift: CALayer?

    var avatarSize: CGFloat?      // avatar 尺寸
    var giftSize: CGFloat?        // gift 尺寸

    var avatarImage:CGSize?
    var giftImage:CGSize?



    var leftPadding: CGFloat = 8
    var textX: CGFloat = 0
    var adjustedY:CGFloat = 0


    var isFadingOut: Bool = false
    var isMoving:Bool = false

    var parentMessageID: UUID? = nil  // 標識同一條長訊息的多個段落
    var segmentIndex: Int = 0         // 這條訊息是第幾段

    var didResolveSize: Bool = false

    var verticalSpacing: CGFloat = 4
    var horizontalSpacing: CGFloat = 6




    var overflowHeight: CGFloat?

    // 🔹 新增快取屬性
    var cachedNameSize: CGSize = .zero
    var cachedMessageSize: CGSize = .zero

    var cachedGiftOffsetX: CGFloat = 0
    var cachedGiftOffsetY: CGFloat = 0

    // MessageLayerTuple 新增
    var lastLineText: String?



    // ⚡ 主要屬性比較用
    static func == (lhs: MessageLayerTuple, rhs: MessageLayerTuple) -> Bool {
        return lhs === rhs // 使用物件引用判斷是否為同一個實例
    }


    init(
        avatar: CALayer?,
        name: CATextLayer?,
        message: CATextLayer?,
        gift: CALayer?,
        type:MessageType = .primary
    ) {
        self.avatar = avatar
        self.name = name
        self.message = message
        self.gift = gift
        self.type = type
    }
}



struct MessageSegmentData {
    let parentID: UUID
    let segmentIndex: Int

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

    let font:UIFont?

    var verticalSpacing: CGFloat = 8.0
    var horizontalSpacing: CGFloat = 8.0

}

final class LayerPool {

    private var textLayers: [CATextLayer] = []
    private var imageLayers: [CALayer] = []

    private let scale = UIScreen.main.scale

    // MARK: - Text

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
        layer.string = nil
        layer.opacity = 1
        layer.frame = .zero
        layer.removeFromSuperlayer()
        textLayers.append(layer)
    }

    // MARK: - Image (avatar / gift 共用)

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
        layer.contents = nil
        layer.opacity = 1
        layer.frame = .zero
        layer.removeFromSuperlayer()
        imageLayers.append(layer)
    }
}



// MARK: - PIP 訊息組（PiP 專用動畫版）
final class PIPServiceMessages {

    // 滾動與漸隱
    var containerHeight: CGFloat { container.bounds.height }
    var scrollSpeed: CGFloat = 0.2           // 每幀上移的像素

    var fadeOutThreshold: CGFloat {
        // 當 stackedMessages 總高度超過 container，最上面那條就應該 fade
        return container.bounds.height - (stackedMessages.reduce(0) { $0 + $1.height } - container.bounds.height)
    }
    // 舊訊息漸隱開始的高度

    private var lastFadeTriggerTime: CFTimeInterval = 0

    var fadeInterval: CFTimeInterval = LPConfig.shared.MessageFadeTime

    // 新增：目前正在淡出的組
    private var fadingParentID: UUID?




    func groupLeader(_ msg: MessageLayerTuple) -> MessageLayerTuple? {
        stackedMessages
            .filter { $0.parentMessageID == msg.parentMessageID }
            .min(by: { $0.segmentIndex < $1.segmentIndex })
    }

    func isGroupFadingOut(_ msg: MessageLayerTuple) -> Bool {
        // 只要這個組內有任何一行正在淡出，就視為整組正在淡出
        return stackedMessages.contains {
            $0.parentMessageID == msg.parentMessageID && $0.isFadingOut
        }
    }


    private func updateFadeCandidateIfNeeded() {
        guard fadeCandidate == nil else {

            return
        }

        // 只考慮已穩定、可見、未 fade 的 leader
        let leaders = stackedMessages
            .filter { !$0.isNew && !$0.isFadingOut && $0.alpha > 0 }
            .compactMap { groupLeader($0) }
            .filter {
                abs($0.startY - $0.targetY) < snapThreshold &&
                $0.targetY + $0.height <= container.bounds.height
            }


        // 🔑 關鍵：用 targetY，不是 startY
        fadeCandidate = leaders.min(by: { $0.targetY < $1.targetY })
        PIPChatLog(
            "FadeCan:\(String(describing: fadeCandidate?.name?.string))-\(String(describing: fadeCandidate?.message?.string)) \(String(describing: fadeCandidate?.parentMessageID)) SY:\(String(describing: fadeCandidate?.startY)) TY:\(String(describing: fadeCandidate?.targetY))"
        )
        if fadeCandidate != nil {
            lastFadeTriggerTime = CACurrentMediaTime()
            fadingParentID = fadeCandidate!.parentMessageID

        }
    }


    // MARK: - Properties
    let container = CALayer()

    var stackedMessages: [MessageLayerTuple] = []   // 一般聊天

    private var bottomMessage: MessageLayerTuple?           // 底部固定




    private var animatingMessages: [MessageLayerTuple] = []

    var font: UIFont = .systemFont(ofSize: 16)
    var lineHeight: CGFloat = 20
    var avatarSize: CGFloat = 28
    var giftSize: CGFloat = 28

    var topMargin: CGFloat {
        max(65, container.bounds.height * 0.18)
    }


    private var lastDirtyTime: CFTimeInterval = 0

    //private var isAnyMessageFadingOut: Bool = false

    private var needsRelayoutAfterRemoval = false


    // ✅ 新增（fade 決策只算一次）
    private var fadeCandidate: MessageLayerTuple?

    let bottomPadding: CGFloat = 4

    private var safeCanncel: Bool = false

    deinit {

        logTo("Deinit OK")

    }

    func canncel() {
        safeCanncel = true
        logTo("已取消使用")

    }



    // Animation
    private var isAnimating = false
    private var displayLink: CADisplayLink?
    private var hasLaidOutOnce = false



    init(size: CGSize) {
        container.frame = CGRect(origin: .zero, size: size)
        container.masksToBounds = true
    }



    private func relayoutTargetsOnly(updateTargetY: Bool = true) {

        //let bottomMsgHeight = bottomMessage?.height ?? 0

        // 🔑 1️⃣ 用「目前畫面順序」排序
        let relayoutMessages = stackedMessages
            .filter {
                $0.alpha > 0 &&
                $0.didResolveSize
            }

        var yCursor = topMargin

        // 先按 segmentIndex 排序，保證全局順序
        let orderedMessages = relayoutMessages
            .sorted { lhs, rhs in
                // 先按 parentMessageID 的出現順序
                if lhs.parentMessageID == rhs.parentMessageID {
                    return lhs.segmentIndex < rhs.segmentIndex
                } else {
                    if lhs.startY <= 0 {
                        lhs.startY = rhs.startY + lhs.height
                    }

                    return stackedMessages.firstIndex(of: lhs)! < stackedMessages.firstIndex(of: rhs)!
                }
            }


        for msg in orderedMessages {
            if updateTargetY {
                msg.targetY = yCursor

            }
            PIPChatLog(
                "Name:\(String(describing: msg.name?.string))\nMES:\(String(describing: msg.message?.string))\n\(msg.startY)->\(msg.targetY)\nUID:\(String(describing: msg.parentMessageID))"
            )

            if msg.name == nil {
                yCursor += msg.height

            } else {
                yCursor += msg.height + msg.verticalSpacing
            }
        }



        //layoutBottomMessage()
        //updateBottomVisibility()


        // ✅ 只在「第一次完成 targetY 計算」後標記
        if !hasLaidOutOnce {
            hasLaidOutOnce = true
            PIPChatLog("First layout baseline established")
        }

    }


    var leftPadding: CGFloat = 8



    func breakMessageIntoLines(_ text: String, font: UIFont, maxWidth: CGFloat) -> [String] {
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let framesetter = CTFramesetterCreateWithAttributedString(attr)

        let path = CGPath(rect: CGRect(x: 0, y: 0, width: maxWidth, height: .greatestFiniteMagnitude), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attr.length), path, nil)

        let lines = CTFrameGetLines(frame) as! [CTLine]
        var result: [String] = []

        for line in lines {
            let range = CTLineGetStringRange(line)
            let nsRange = NSRange(location: range.location, length: range.length)
            let substring = (text as NSString).substring(with: nsRange)
            result.append(substring)
        }

        return result
    }

    private func splitLongMessage(
        type:MessageType,
        user: String,
        message: String,
        imgURL: String?,
        giftURL: String?,
        font: UIFont,
        avatarSizeLocal: CGFloat,
        giftSizeLocal: CGFloat,
        vSpacing:CGFloat = 8,
        hSpacing:CGFloat = 8
    ) -> [MessageSegmentData] {


        var result: [MessageSegmentData] = []

        var seg = 0

        let parentID = UUID()


        // ⚠️ 計算可用寬度（跟 buildMessageTuple 一致）
        let maxMessageWidth = container.bounds.width
            - leftPadding * 2
            - avatarSizeLocal
            - 8 // horizontalSpacing
            - giftSizeLocal


        let nameLines = breakMessageIntoLines(
            user,
            font: font,
            maxWidth: maxMessageWidth
        )


        // ① 名稱段（可能多行）
        for (index, line) in nameLines.enumerated() {

            let isFirst = index == 0

            let data = MessageSegmentData(
                    parentID: parentID,
                    segmentIndex: seg,
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
                    font:font,
                    verticalSpacing:vSpacing,
                    horizontalSpacing: hSpacing

                )


            seg += 1


            PIPChatLog(
                "Split segment \(index): text='\(line)'"
            )


            result.append(data)
        }


        let messageLines = breakMessageIntoLines(
            message,
            font: font, maxWidth: maxMessageWidth
        )


        for (index, line) in messageLines.enumerated() {

            let isLast = index == messageLines.count - 1

            let data = MessageSegmentData(
                    parentID: parentID,
                    segmentIndex: seg,
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
                    font: font
                )



            seg += 1


            PIPChatLog(
                "Split segment \(index): text='\(line)'"
            )


            result.append(data)
        }

        return result
    }



    // MARK: - Build Message Tuple（抽出來重用）
    func buildMessageTuple(
        type:MessageType = .primary,
        user: String,
        message: String,
        img: UIImage?,
        giftImg: UIImage?,
        showAvatar: Bool,
        showName: Bool,
        showMessage:Bool = true,
        showGift:Bool = false,
        font: UIFont,
        avatarSizeLocal: CGFloat,
        giftSizeLocal: CGFloat,
        verticalSpacing:CGFloat = 8,
        horizontalSpacing:CGFloat = 8


    ) -> MessageLayerTuple {


        // Avatar
        var avatarLayer :CALayer?

        if showAvatar {
            let layer = CALayer()
            layer.contents = img?.cgImage
            layer.contentsGravity = .resizeAspectFill
            layer.frame = CGRect(
                x: leftPadding,
                y: container.bounds.height,
                width: avatarSizeLocal,
                height: avatarSizeLocal
            )

            // ✅ 讓圖片圓形
            layer.cornerRadius = avatarSizeLocal / 2
            layer.masksToBounds = true


            container.addSublayer(layer)
            avatarLayer = layer

        }

        // Name
        var nameLayer: CATextLayer?

        if showName {
            let layer = CATextLayer()

            layer.string = user
            layer.font = font
            layer.fontSize = font.pointSize
            layer.foregroundColor = UIColor.white.cgColor
            layer.contentsScale = UIScreen.main.scale
            layer.isWrapped = true
            layer.truncationMode = .none

            layer.alignmentMode = .left

            container.addSublayer(layer)
            nameLayer = layer

        }

        // Message
        var messageLayer: CATextLayer?

        if showMessage {

            let layer = CATextLayer()
            layer.string = message
            layer.font = font
            layer.fontSize = font.pointSize
            layer.foregroundColor = UIColor.white.cgColor
            layer.contentsScale = UIScreen.main.scale
            layer.isWrapped = true
            layer.truncationMode = .none

            layer.alignmentMode = .left
            container.addSublayer(layer)
            messageLayer = layer
        }

        // Gift
        var giftLayer: CALayer?

        if showGift {
            let layer = CALayer()
            layer.contents = giftImg?.cgImage
            layer.contentsGravity = .resizeAspect

            container.addSublayer(layer)
            giftLayer = layer
        }


        let tuple = MessageLayerTuple(
            avatar: avatarLayer ,
            name: nameLayer ,
            message: messageLayer,
            gift: giftLayer
        )

        tuple.font = font
        tuple.avatarSize = avatarSizeLocal
        tuple.giftSize = giftSizeLocal

        tuple.verticalSpacing = verticalSpacing
        tuple.horizontalSpacing = horizontalSpacing
        tuple.isNew = true
        tuple.alpha = 1.0

        tuple.type = type

        tuple.textX = leftPadding
            + (showAvatar ? avatarSizeLocal + horizontalSpacing : 0)


        let avatarWidth = showAvatar ? avatarSizeLocal + horizontalSpacing : 0
        let giftWidth   = showGift ? giftSizeLocal + horizontalSpacing : 0

        // 🔹 同步計算高度
        let maxNameWidth = container.bounds.width
            - leftPadding * 2
            - avatarWidth

        let maxMessageWidth = container.bounds.width
            - leftPadding * 2
            - avatarWidth
            - giftWidth


        let nameHeight = showName
            ? (user as NSString).boundingRect(
                with: CGSize(width: maxNameWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            ).height
            : 0


        let messageHeight = showMessage ? (message as NSString).boundingRect(
            with: CGSize(width: maxMessageWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height : font.lineHeight



        tuple.cachedNameSize = CGSize(width: maxNameWidth, height: nameHeight)

        tuple.cachedMessageSize = CGSize(width: maxMessageWidth, height: messageHeight)


        if showGift, showMessage {

            let attr = NSAttributedString(
                string: message,
                attributes: [.font: font]
            )

            let frameHeight = tuple.cachedMessageSize.height

            let framesetter = CTFramesetterCreateWithAttributedString(attr)
            let path = CGPath(
                rect: CGRect(
                    x: 0,
                    y: 0,
                    width: maxMessageWidth,
                    height: frameHeight
                ),
                transform: nil
            )

            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: attr.length),
                path,
                nil
            )

            let lines = CTFrameGetLines(frame) as! [CTLine]
            guard let lastLine = lines.last else { return tuple }

            // 最後一行文字寬度
            let lastLineWidth = CGFloat(
                CTLineGetTypographicBounds(lastLine, nil, nil, nil)
            )

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0

            CTLineGetTypographicBounds(lastLine, &ascent, &descent, &leading)


            // baseline
            var origins = Array(repeating: CGPoint.zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), &origins)

            let lastLineOrigin = origins.last!

            // 快取 gift 相對 message 左上角的位置
            tuple.cachedGiftOffsetX = lastLineWidth + 2

            let rawY = lastLineOrigin.y


            // 微調
            let visualOffset: CGFloat = 2.0  // 或 1~3，視覺測試


            if rawY.isFinite {
                tuple.cachedGiftOffsetY =
                tuple.cachedMessageSize.height
                - rawY
                - ascent / 2
                - giftSizeLocal / 2
                + visualOffset

            } else {
                // 🔥 fallback：直接貼在最後一行中線
                    tuple.cachedGiftOffsetY =
                        tuple.cachedMessageSize.height
                        - ascent / 2
                        - giftSizeLocal / 2
                        + visualOffset

            }


        }


        // 計算最後一行文字寬度（用 constrained width 模擬）
        tuple.lastLineText = breakMessageIntoLines(
            message,
            font: font,
            maxWidth: maxMessageWidth
        ).last


        var textBlockHeight: CGFloat = 0

        if showName {
            textBlockHeight += nameHeight
        }


        if showName && showMessage {
            textBlockHeight += verticalSpacing
        }

        if showMessage {
            textBlockHeight += messageHeight
        }



        tuple.height = textBlockHeight

        if type == .secondary {
            tuple.height += 2
        }

        tuple.didResolveSize = true


        return tuple
    }







    // MARK: - Add Message（Chunk 修正版，可直接替換）
    func addMessage(
        user: String,
        message: String,
        imgURL: String? = nil,
        giftURL: String? = nil,
        isMain: Bool = true
    ) {


        let type: MessageType = isMain ? .primary : .secondary

        let fontSize: CGFloat = (
            type == .primary
        ) ? LPConfig.shared.PIPChatFontMainSize : LPConfig.shared.PIPChatFontSecondSize

        let avatarSizeLocal: CGFloat = (
            type == .primary
        ) ? LPConfig.shared.PIPChatFontMainSize : LPConfig.shared.PIPChatFontSecondSize

        let giftSizeLocal: CGFloat = (
            type == .primary
        ) ? LPConfig.shared.PIPChatFontMainSize : LPConfig.shared.PIPChatFontSecondSize


        let font = UIFont.systemFont(ofSize: fontSize)

        // secondary 不 chunk
        if type == .secondary {

//                let tuple = self.buildMessageTuple(
//                    type:.secondary,
//                    user: user,
//                    message: message,
//                    img: nil,
//                    giftImg: nil,
//                    showAvatar: true,
//                    showName: true,
//                    showGift: true,
//                    font: font,
//                    avatarSizeLocal: avatarSizeLocal,
//                    giftSizeLocal: giftSizeLocal,
//
//                )

//            verticalSpacing = 4.0
//            horizontalSpacing = 6.0

        }


            let segments = self.splitLongMessage(
                type: type, user: user,
                message: message,
                imgURL:imgURL,
                giftURL: giftURL,
                font: font,
                avatarSizeLocal: avatarSizeLocal,
                giftSizeLocal: giftSizeLocal

            )


            // ① 先只存資料
            pendingSegments.append(contentsOf: segments)

            // ② 嘗試補畫面
            populateVisibleMessagesIfNeeded()

            self.layoutTargetsAndStartAnimation()







    }


    private var pendingSegments: [MessageSegmentData] = []

    func currentBottomTargetY() -> CGFloat {
        stackedMessages
            .filter { !$0.isNew }   // 排除還在進場的
            .map { $0.targetY + $0.height }
            .max()
        ?? topMargin
    }

    func canInsertMessage(_ newMsg: MessageLayerTuple) -> Bool {
        // 模擬累加
        var simulatedBottomY = currentBottomTargetY()

        // 如果有多條新訊息要插，這裡可以改成迴圈累加
        simulatedBottomY += newMsg.height


        let canInsert = simulatedBottomY <= container.bounds.height + newMsg.height

        PIPChatLog("CanInsert \(canInsert) SSTY:\(simulatedBottomY) Bounds:\(container.bounds.height + newMsg.height)")

        return canInsert
    }

    func populateVisibleMessagesIfNeeded() {

        while let data = pendingSegments.first {


            guard let font = data.font,
                  let avatarSize = data.avatarSizeLocal,
                  let giftSize = data.giftSizeLocal
            else { return }

            let msg = buildMessageTuple(
                type: data.type,
                user: data.user,
                message: data.message,
                img: nil, //先設 nil，用 URL 下載
                giftImg: nil, //先設 nil，用 URL 下載
                showAvatar: data.showAvatar, // 只有第一行顯示 avatar,
                showName: data.showName,
                showMessage:data.showMessage,   // 只有第一行顯示名字
                showGift: data.showGift, // 最後一行顯示禮物
                font: font,
                avatarSizeLocal: avatarSize,
                giftSizeLocal: giftSize,
                verticalSpacing: data.verticalSpacing,
                horizontalSpacing: data.horizontalSpacing
                     )

            msg.parentMessageID = data.parentID
            msg.segmentIndex = data.segmentIndex


            guard canInsertMessage(msg) else {
                // 放不下就不要 build
                break
            }


            pendingSegments.removeFirst()


            if let avatarURL = data.avatarURL {
                Task {
                    await PiPImageCache.shared
                        .loadImage(urlString: avatarURL) { image in
                            msg.avatar?.contents = image?.cgImage
                            msg.avatarImage = image?.size
                        }
                }
            }
            if let giftURL = data.giftURL {
                Task {
                    await PiPImageCache.shared
                        .loadImage(urlString: giftURL) { image in
                            msg.gift?.contents = image?.cgImage
                            msg.giftImage = image?.size
                        }
                }
            }

            stackedMessages.append(msg)
        }
    }


    // MARK: 之前固定於底部用的考慮棄用或提換成別的
    //    private func layoutBottomMessage() {
    //        guard let msg = bottomMessage else { return }
    //
    //        //let y = bottomPadding
    //        let y = container.bounds.height - msg.height - bottomPadding
    //        //let x = 80.0
    //
    //        PIPChatLog(
    //            "Debug Bottom? \(String(describing: msg.message?.string)) \(String(describing: msg.message?.opacity))"
    //        )
    //        layout(msg: msg, y: y)
    //    }

    // MARK: 更新底部訊息

    //    func updateBottomVisibility() {
    //        guard let bottom = bottomMessage else { return }
    //
    //        let shouldHide = IshasOverFlow()
    //
    //        // 如果是 secondary，永遠顯示
    //        let isSecondary = bottom.type == .secondary
    //
    //        let targetOpacity: Float = isSecondary ? 1.0 : (shouldHide ? 0.0 : 1.0)
    //
    //
    //        if bottom.avatar?.opacity != targetOpacity {
    //            bottom.avatar?.opacity = targetOpacity
    //            bottom.name?.opacity = targetOpacity
    //            bottom.message?.opacity = targetOpacity
    //            bottom.gift?.opacity = targetOpacity
    //        }
    //    }

    // MARK: 舊的替換底部文字

    //    private func replaceBottomMessage(_ newMsg: MessageLayerTuple) {
    //
    //        // 移除舊的
    //        if let old = bottomMessage {
    //            old.avatar?.removeFromSuperlayer()
    //            old.name?.removeFromSuperlayer()
    //            old.message?.removeFromSuperlayer()
    //            old.gift?.removeFromSuperlayer()
    //        }
    //
    //        bottomMessage = newMsg
    //
    //        layoutBottomMessage()
    //        updateBottomVisibility()
    //        PIPService.shared.markDirty()
    //
    //    }





    func IshasOverFlow() -> Bool {


        // 找出最底部訊息的 targetY + height
        guard let maxBottom = stackedMessages
            .filter({ $0.alpha > 0 }) // 忽略已消失訊息
            .map({ $0.targetY + $0.height })
            .max() else { return false }


        let conSize = container.bounds.height - bottomPadding
        PIPChatLog("MaxBottom:\(maxBottom) Container:\(conSize)")
        return maxBottom  > conSize


    }



    let snapThreshold: CGFloat = 0.2

    // MARK: - Layout + Animation 修正版（可直接替換）
    func layoutTargetsAndStartAnimation() {

        // 🔑 一定要先算 targetY（否則動畫會拉到 0）
        relayoutTargetsOnly(updateTargetY: true)

        // Debug 輸出
        PIPChatLog("--- layoutTargets ---")


        // 將 stackedMessages 按 targetY 排序，從上到下
        let sortedStack = stackedMessages
            .filter { $0.alpha > 0 }

        var lastSY = container.bounds.height

        for msg in sortedStack {
            // 新訊息且還沒在 animatingMessages
            guard msg.isNew else { continue }

            if !animatingMessages.contains(msg) {

                msg.startY = lastSY + msg.height
                lastSY = msg.startY
                PIPChatLog("lastSY:\(lastSY) Target SY:\(msg.startY)")
                animatingMessages.append(msg)

            }
        }


        PIPService.shared.markDirty()
        PIPService.shared.isAnimatingMessages = true


        // 啟動 displayLink
        if displayLink == nil {
            displayLink = CADisplayLink(target: self, selector: #selector(stepAnimationDisplayLink))
            displayLink?.add(to: .main, forMode: .common)
            isAnimating = true
        }


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






    // MARK: - 每幀動畫
    @objc private func stepAnimationDisplayLink() {

        PIPChatLog("Debug step is doing \(Date().formatted())")
        PIPChatLog(
            "DL step | anim:\(animatingMessages.count)"
        )


        var messagesToRemove: [MessageLayerTuple] = []


        var lastBottomYByParent: [UUID: CGFloat] = [:]

        // ⚠️ 一定要用畫面順序（targetY / segmentIndex）
        let orderedMessages = animatingMessages.sorted {
            if $0.parentMessageID == $1.parentMessageID {
                return $0.segmentIndex < $1.segmentIndex
            }

            let i0 = stackedMessages.firstIndex(of: $0) ?? 0
            let i1 = stackedMessages.firstIndex(of: $1) ?? 0

            return i0 < i1
        }





        for msg in orderedMessages {

                let distance = msg.targetY - msg.startY

                if abs(distance) < snapThreshold {
                    msg.startY = msg.targetY
                    msg.isNew = false
                    messagesToRemove.append(msg) // 先記錄

                } else {
                    msg.startY += distance * 0.2
                }

                guard let parentID = msg.parentMessageID else { return }

                let previousBottomY = lastBottomYByParent[parentID]

                layout(msg: msg, y: msg.startY,previousBottomY: previousBottomY)

                // 🔑 layout 完後，更新這個 parent 的最新底部
            lastBottomYByParent[parentID] = msg.resolvedBottomY
            }








        // ✅ move 完畢就清掉 animatingMessages
        animatingMessages.removeAll { messagesToRemove.contains($0) }


        // 3️⃣ Fade 最上方舊訊息，保留最下面兩條

        let now = CACurrentMediaTime()

        // ✅ fade 延遲判斷（只處理單一 candidate）
        if let candidate = fadeCandidate,
           !isGroupMoving(candidate.parentMessageID ?? nil),
           CACurrentMediaTime() - lastFadeTriggerTime >= fadeInterval,
           !candidate.isNew {


            // 取得這組還有 alpha > 0 的最上方訊息
            let bottomY  = stackedMessages
                   .filter({ $0.alpha > 0 })
                   .map { $0.targetY + $0.height }
                   .max() ?? topMargin


            if bottomY > container.bounds.height - bottomPadding {

                //isAnyMessageFadingOut = true
                candidate.isFadingOut = true
                // 逐行淡出
                candidate.alpha -= 0.04
                candidate.avatar?.opacity = Float(candidate.alpha)
                candidate.name?.opacity = Float(candidate.alpha)
                candidate.message?.opacity = Float(candidate.alpha)
                candidate.gift?.opacity = Float(candidate.alpha)

                // 消失就移除
                if candidate.alpha <= 0.01 {
                    candidate.avatar?.removeFromSuperlayer()
                    candidate.name?.removeFromSuperlayer()
                    candidate.message?.removeFromSuperlayer()
                    candidate.gift?.removeFromSuperlayer()
                    candidate.isFadingOut = false

                    if let idx = stackedMessages.firstIndex(where: { $0 === candidate }) {
                        stackedMessages.remove(at: idx)
                    }
                    animatingMessages.removeAll { $0 === candidate }
                    animatingMessages.removeAll { $0.alpha <= 0 }

                    fadeCandidate = nil

                    needsRelayoutAfterRemoval = true


                }

            } else {
                // 超過 container 的部分已經 fade 完，停止

                if !isHasFade(candidate.parentMessageID ?? nil) {
                    logTo("沒有此ＩＤ訊息")
                    fadingParentID = nil
                }

                fadeCandidate = nil

            }



        }











        let hasMoving = stackedMessages.contains { msg in
            abs(msg.startY - msg.targetY) >= snapThreshold
        }



        // 5️⃣ 動畫完成判斷
        let hasMovingOrFading = hasMoving || fadeCandidate != nil


        let shouldContinueBecauseOverflow =
            IshasOverFlow() && (fadeCandidate != nil)


        let isWaitingForFadeDelay = fadeCandidate != nil  &&
            lastFadeTriggerTime != 0 &&
        now - lastFadeTriggerTime < fadeInterval  // fadeDelay

        PIPChatLog("hasMovingOrFading?\(hasMovingOrFading) - isWaitFor:\(isWaitingForFadeDelay) NowWait:\(now-lastFadeTriggerTime) < \(fadeInterval)? needRelay:\(needsRelayoutAfterRemoval)")


        if !hasMoving &&
           fadeCandidate == nil &&
           IshasOverFlow() {

            updateFadeCandidateIfNeeded()
        }

        if !hasMovingOrFading &&
            !isWaitingForFadeDelay &&
            !shouldContinueBecauseOverflow &&
            !needsRelayoutAfterRemoval ||
            safeCanncel {



            var lastBottomYByParent: [UUID: CGFloat] = [:]

            let orderedMessages = animatingMessages.sorted {
                if $0.parentMessageID == $1.parentMessageID {
                    return $0.segmentIndex < $1.segmentIndex
                }

                let i0 = stackedMessages.firstIndex(of: $0) ?? 0
                let i1 = stackedMessages.firstIndex(of: $1) ?? 0

                return i0 < i1
            }


            for msg in orderedMessages {
                  msg.startY = msg.targetY
                  msg.isNew = false

                  guard let parentID = msg.parentMessageID else { return }

                  let previousBottomY = lastBottomYByParent[parentID]

                  layout(
                        msg: msg,
                        y: msg.targetY ,
                        previousBottomY: previousBottomY
                  )

                  // 🔑 layout 完後，更新這個 parent 的最新底部
                lastBottomYByParent[parentID] = msg.resolvedBottomY
            }

            // ✅ 清掉已經穩定的 animatingMessages（非常重要）
            animatingMessages.removeAll {
                abs($0.startY - $0.targetY) < snapThreshold
            }


            // 🔥 如果還 overflow，立刻重新進入 fade 流程
            if IshasOverFlow() && !safeCanncel {
                updateFadeCandidateIfNeeded()
                // 強制繼續跑 displayLink
                if fadeCandidate == nil {
                    return
                }


                return
            }



            displayLink?.invalidate()
            displayLink = nil
            isAnimating = false
            animatingMessages.forEach { $0.isNew = false }



            Task { @MainActor in
                PIPService.shared.isAnimatingMessages = false
                PIPService.shared.startDecayAfterAnimation()
            }

            return // ✅ 不再重啟 displayLink
        }

        //layoutBottomMessage()



        // 6️⃣ needsRelayoutAfterRemoval 只做 layout，不重啟 displayLink
        if needsRelayoutAfterRemoval {
            needsRelayoutAfterRemoval = false

            relayoutTargetsOnly(updateTargetY: true)


            // 2️⃣ 把「位置改變的舊訊息」加入動畫
            for msg in stackedMessages {
                guard msg.alpha > 0 else { continue }

                let distance = abs( msg.startY - msg.targetY)

                if distance > snapThreshold && !animatingMessages
                    .contains(msg) {
                    animatingMessages.append(msg)

                }
            }


        }

        // 7️⃣ 更新 dirty 狀態
        if now - lastDirtyTime > 1.0 / 10 {
            lastDirtyTime = now
            PIPService.shared.decyDead()
        }
    }


    private func layout(msg: MessageLayerTuple, y: CGFloat,x:CGFloat? = nil,previousBottomY: CGFloat? = nil) {

        let adjustedY = max(y, topMargin)

        msg.adjustedY = adjustedY

        let avatarSizeLocal = msg.avatarSize ?? self.avatarSize
        let giftSizeLocal = msg.giftSize ?? self.giftSize


        let textX = leftPadding + avatarSizeLocal + msg.horizontalSpacing


        // Avatar
        msg.avatar?.frame.origin.y = adjustedY

        msg.avatar?.frame.origin.x = textX - avatarSizeLocal

        // Name（不再計算）
        let nameSize = msg.cachedNameSize

        msg.name?.frame = CGRect(
            x: textX,
            y: adjustedY,
            width: nameSize.width,
            height: nameSize.height
        )

        

        if let nameLayer = msg.name  {

            // 第一行的 top
            let textCenterY = nameLayer.frame.origin.y + nameLayer.frame.height / 2
            msg.avatar?.frame.origin.y = textCenterY - avatarSizeLocal / 2

        }


        // Message（不再計算）
        var messageY: CGFloat = 0

        var bottomY = adjustedY

        if let nameLayer = msg.name {
            messageY = nameLayer.frame.maxY + msg.verticalSpacing

            bottomY = nameLayer.frame.maxY


        } else if let previousBottomY {

            // ② 同 parent 的後續 segment（🔥 你現在的情況）
            messageY = previousBottomY + msg.verticalSpacing

        }

        else {
            messageY = adjustedY
        }


        let messageSize = msg.cachedMessageSize

        msg.message?.frame = CGRect(
            x: textX,
            y: messageY,
            width: messageSize.width,
            height: messageSize.height
        )

        // Gift（不再算 lastLine）

        if let gift = msg.gift,
           let messageLayer = msg.message {

            bottomY = max(bottomY, messageLayer.frame.maxY)



            let minX = messageLayer.frame.minX
            let minY = messageLayer.frame.minY

            let GiftCX = msg.cachedGiftOffsetX
            let GiftCY = msg.cachedGiftOffsetY

            bottomY = max(bottomY, gift.frame.maxY)


            PIPChatLog("Mes MinX:\(minX) MinY:\(minY) Gift X:\(GiftCX) Y:\(GiftCY)")
            gift.frame = CGRect(
                x: minX + GiftCX,
                y: minY + GiftCY,
                width: giftSizeLocal,
                height: giftSizeLocal
            )


        }



        msg.resolvedBottomY = bottomY


    }

    private func easeOutCubic(_ t: Double) -> Double {
        1 - pow(1 - t, 3)
    }
}


func PIPChatLog(_ message:String){

    logger.debug("PIPCHAT \(message)")

    if LPConfig.shared.PIPChatLog {
        sendlog(title:"[PIP_Chat]",message: message)
    }
}

struct DebugImageViewWrapper: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)

        // 設定 debugImageView
        //PIPService.shared.setupDebugImageView(in: container,
        //                                     frame: CGRect(x: 0, y: 0, width: 150, height: 100))


        //PIPService.shared.setupDebugDisplayLayer(in: container)

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct PIPView: View {

    // 狀態管理哪個 PiP 正在啟用
    @State private var isChatPiPActive = false
    @State private var isTestPiPActive = false

    // ✅ 新增，用來輸入手動訊息
    @State private var manualMessage: String = "test"
    @State private var manualUser: String = "User33"

    var body: some View {
        VStack(spacing: 20) {
            Text("Chat")

            // 水平排列聊天組與測試組按鈕
            HStack(spacing: 20) {
                VStack(spacing: 10) {
                    Button("[聊天組]啟動 PiP") {
                        let pipSize = CGSize(width: 300, height: 200)
                        PIPService.shared.startPiP(size: pipSize)
                        isChatPiPActive = true
                    }
                    .disabled(isTestPiPActive) // 測試組啟用時灰掉

                    Button("[聊天室]停止 PiP") {
                        PIPService.shared.stopPiP()
                        isChatPiPActive = false
                    }
                    .disabled(!isChatPiPActive)
                }

                VStack(spacing: 10) {
                    Button("[測試組]啟動 PiP") {
                        PIPTestService.shared.startPiPTest(size: CGSize(width: 300, height: 200))
                        isTestPiPActive = true
                    }
                    .disabled(isChatPiPActive) // 聊天組啟用時灰掉

                    Button("[測試組]停止 PiP") {
                        PIPTestService.shared.stopPiP()
                        isTestPiPActive = false
                    }
                    .disabled(!isTestPiPActive)
                }
            }

            VStack(spacing: 10) {
                // ✅ 新增 TextField
                TextField("輸入手動用戶名", text: $manualUser)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                TextField("輸入手動訊息", text: $manualMessage)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                // 手動新增訊息按鈕
                Button("新增訊息") {
                    let imgA = "https://img.icons8.com/?size=100&id=12860&format=png&color=000000"
                    let imgG = "https://img.icons8.com/?size=100&id=y5xu7jml0MTU&format=png&color=000000"

                    // 把 TextField 內容傳給 PIPService
                    PIPService.shared
                        .addMessage(
                            user: manualUser,
                            msg: manualMessage,
                            imgURL: imgA,
                            giftURL: imgG
                        )



                }

            }



            Button("測試長訊息") {

                let user =  "1阿呵呵呵阿呵呵呵阿呵呵呵阿呵呵呵2阿呵呵呵阿呵呵呵阿呵呵3呵阿呵呵呵阿呵呵呵阿呵呵呵阿4呵呵呵阿呵呵呵阿呵呵呵阿呵呵呵阿呵呵呵測試5"

                let msg =  "1阿呵呵呵阿呵呵呵2阿呵呵呵阿呵呵呵阿呵呵呵阿呵呵呵阿呵3呵呵阿呵呵呵阿呵呵呵阿呵呵呵4阿呵呵呵阿呵呵呵阿呵呵呵測試5"
                let img = "https://img.icons8.com/?size=100&id=L8HgZUgz2jWS&format=png&color=000000"

                let gift = "https://img.icons8.com/?size=100&id=tgLepcPbp6mP&format=png&color=000000"

                PIPService.shared
                    .addMessage(user: user, msg: msg,imgURL: img,giftURL: gift)

            }
            Button("TestB") {
                let imgA = "https://img.icons8.com/?size=100&id=12860&format=png&color=000000"
                let imgG = "https://img.icons8.com/?size=100&id=y5xu7jml0MTU&format=png&color=000000"
                PIPService.shared.addMessage(user: "小明2", msg: "Hello!", imgURL: imgA, giftURL: imgG)
            }

            Button("Test次要訊息") {
                let imgA = "https://img.icons8.com/?size=100&id=12860&format=png&color=000000"
                let imgG = "https://img.icons8.com/?size=100&id=y5xu7jml0MTU&format=png&color=000000"
                PIPService.shared.addMessage(user: "小明2", msg: "Hello!", imgURL: imgA, giftURL: imgG, isMain: false)
            }

            Button("新增訊息") {
                PIPService.shared.addMessage(
                    msg: "測試訊息圖片",
                    imgURL: "https://img.icons8.com/?size=100&id=12860&format=png&color=000000",
                    giftURL: "https://img.icons8.com/?size=100&id=y5xu7jml0MTU&format=png&color=000000"
                )
            }

            // 將 debugImageView 顯示在 SwiftUI
            DebugImageViewWrapper()
                .frame(width: 150, height: 100)
                .border(Color.red)
        }
        .padding()
    }
}
// 這是一個你自訂的內容（聊天室/動畫等）
