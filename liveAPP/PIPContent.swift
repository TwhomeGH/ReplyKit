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
        cache.countLimit = 10
        cache.totalCostLimit = 10 * 1024 * 1024
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


                Task {
                    if let img = UIImage(data: data) {
                        cache.setObject(img, forKey: urlString as NSString)
                        await MainActor.run {
                            completion(img)
                        }
                    }
                    self.finishDownload(urlString: urlString)
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
    let insertionIndex: Int

    var initialStartY: CGFloat = 0

    // MessageLayerTuple
    var hasAvatarSlot: Bool = false

    // layout
    var isNew: Bool = false      // 是否新訊息
    var startY: CGFloat = 0      // 動畫起始 y
    var targetY: CGFloat = 0     // 動畫目標 y
    var height: CGFloat = 0      // 訊息總高度

    // 透明度控制，用於漸隱
    var alpha: CGFloat = 1.0
    // ⚡ 新增支援訊息大小的屬性
    var font: UIFont?             // 訊息字體

    var name: CATextLayer?
    var message: CATextLayer?
    var avatar: CALayer?
    var gift: CALayer?

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
    var horizontalSpacing: CGFloat = 4




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
        type:MessageType = .primary,
        insertionIndex:Int
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

    private var insertionCounter: Int = 0

    // MARK: 動畫狀態機
    enum AnimationPhase {
        case moving
        case fading
        case waitFading
        case pending

        case idle
    }

    private var phase: AnimationPhase = .idle

    // DisplayLink 專用（只讀）
    private var animatingGroups: [[MessageLayerTuple]] = []

    // 滾動與漸隱
    var containerHeight: CGFloat { container.bounds.height }
    var scrollSpeed: CGFloat // 每幀上移的像素

    var fadeOutThreshold: CGFloat {
        // 當 stackedMessages 總高度超過 container，最上面那條就應該 fade
        return container.bounds.height - (stackedMessages.reduce(0) { $0 + $1.height } - container.bounds.height)
    }
    // 舊訊息漸隱開始的高度

    private var lastFadeTriggerTime: CFTimeInterval = 0
    private var lastMoveTriggerTime: CFTimeInterval = 0


    var fadeInterval: CFTimeInterval = LPConfig.shared.MessageFadeTime

    // 新增：目前正在淡出的組
    private var fadingParentID: UUID?

    func groupLeader(_ msg: MessageLayerTuple) -> MessageLayerTuple? {
        stackedMessages
            .filter { $0.parentMessageID == msg.parentMessageID }
            .min(by: { $0.segmentIndex < $1.segmentIndex })
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



    init(size: CGSize,scrollSpeed:CGFloat = 0.2) {
        container.frame = CGRect(origin: .zero, size: size)
        container.masksToBounds = true

        self.scrollSpeed = scrollSpeed
        
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

        // 2️⃣ 按 group 分組，再組內按 segmentIndex 排序
        let grouped = Dictionary(grouping: moving, by: { $0.parentMessageID })
            .values
            .map { $0.sorted { $0.segmentIndex < $1.segmentIndex } }

        // 3️⃣ 再按組的最上方 targetY 排序
        let orderedGroups = grouped.sorted { group1, group2 in
            (group1.first?.targetY ?? 0) < (group2.first?.targetY ?? 0)
        }

        animatingGroups = orderedGroups

    }

    private func relayoutTargetsOnly(updateTargetY: Bool = true,changeSY:Bool=true) -> [MessageLayerTuple] {


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


                if changeSY {
                    if lhs.startY <= 0 {
                        lhs.startY = rhs.startY + lhs.height
                    }
                    if rhs.startY <= 0 {
                        rhs.startY = lhs.startY + rhs.height
                    }
                }



                // 先按 parentMessageID 的出現順序
                if lhs.parentMessageID == rhs.parentMessageID {
                    return lhs.segmentIndex < rhs.segmentIndex
                } else {

                    return lhs.insertionIndex < rhs.insertionIndex

                }
            }


        for (index,msg) in orderedMessages.enumerated() {
            if updateTargetY {
                msg.targetY = yCursor

            }


            PIPChatLog(
                "index:\(index) Name:\(String(describing: msg.name?.string))\nMES:\(String(describing: msg.message?.string))\n\(msg.startY)->\(msg.targetY)\nUID:\(String(describing: msg.parentMessageID))"
            )

            if msg.name == nil {
                yCursor += msg.height

            } else {
                yCursor += msg.height + msg.verticalSpacing
            }
        }




        // ✅ 只在「第一次完成 targetY 計算」後標記
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
            // fallback：直接貼在 message 中心
            return (0, (messageSize.height - giftSize) / 2)
        }

        // 最後一行文字寬度
        let lastLineWidth = CGFloat(CTLineGetTypographicBounds(lastLine, nil, nil, nil))

        // baseline
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

        // 微調 visual offset
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
        font: UIFont,
        avatarSizeLocal: CGFloat,
        giftSizeLocal: CGFloat,
        vSpacing:CGFloat = 4.0,
        hSpacing:CGFloat = 4.0
    ) -> [MessageSegmentData] {


        var result: [MessageSegmentData] = []

        var seg = 0

        let parentID = UUID()


        // ⚠️ 計算可用寬度（跟 buildMessageTuple 一致）
        let maxMessageWidth = container.bounds.width
            - vSpacing * 2
            - avatarSizeLocal
            - hSpacing // horizontalSpacing
            - giftSizeLocal


        let (nameLines,nameCTLine) = breakMessageIntoLines(
            user,
            font: font,
            maxWidth: maxMessageWidth
        )


        // ① 名稱段（可能多行）
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
                    CGSize(width: maxMessageWidth, height: .greatestFiniteMagnitude),
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


        for (index, line) in messageLines.enumerated() {

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
        verticalSpacing:CGFloat = 4,
        horizontalSpacing:CGFloat = 4,
        data: MessageSegmentData


    ) -> MessageLayerTuple {


        // Avatar
        var avatarLayer :CALayer?

        if showAvatar {
            let layer = CALayer()
            layer.contents = img?.cgImage
            layer.contentsGravity = .resizeAspectFill
            layer.frame = CGRect(
                x: horizontalSpacing,
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
            gift: giftLayer, insertionIndex: insertionCounter
        )

        insertionCounter += 1

        tuple.font = font
        tuple.avatarSize = avatarSizeLocal
        tuple.giftSize = giftSizeLocal

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


//        // 🔹 同步計算高度
//        let maxNameWidth = container.bounds.width
//            - horizontalSpacing * 2
//            - avatarWidth

        let maxMessageWidth = data.maxMessageWidth




        tuple.cachedNameSize = data.cachedMessageSize

        // ✅ 只用 cache，完全不算 CoreText
        tuple.cachedMessageSize = data.cachedMessageSize
        tuple.cachedGiftOffsetX = data.cachedGiftOffsetX
        tuple.cachedGiftOffsetY = data.cachedGiftOffsetY



        let (msglast,_) = breakMessageIntoLines(
            message,
            font: font,
            maxWidth: maxMessageWidth
        )

        // 計算最後一行文字寬度（用 constrained width 模擬）
        tuple.lastLineText = msglast.last


        var textBlockHeight: CGFloat = 0

        if showName {
            textBlockHeight += data.cachedMessageSize.height
        }


        if showName && showMessage {
            textBlockHeight += horizontalSpacing
        }

        if showMessage {
            textBlockHeight += data.cachedMessageSize.height
        }



        tuple.height = textBlockHeight

        tuple.startY = containerHeight


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

        let vSpacing = 4.0
        let hSpacing = 16.0



            let segments = self.splitLongMessage(
                type: type, user: user,
                message: message,
                imgURL:imgURL,
                giftURL: giftURL,
                font: font,
                avatarSizeLocal: avatarSizeLocal,
                giftSizeLocal: giftSizeLocal,
                vSpacing: vSpacing,
                hSpacing: hSpacing

            )


            // ① 先只存資料
            pendingSegments.append(contentsOf: segments)

            // ② 嘗試補畫面
            populateVisibleMessagesIfNeeded()

            layoutTargetsAndStartAnimation()







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

        // 1️⃣ 先拿目前已排好的最後一條 target 底部
        let currentBottom = stackedMessages
            .filter { $0.alpha > 0 && !$0.isFadingOut }
            .map { $0.targetY + $0.height }
            .max() ?? topMargin

        // 2️⃣ 新訊息「理論上」會接在這個位置
        let newBottom = currentBottom + newMsg.height + newMsg.verticalSpacing

        // 3️⃣ 容許超出 15%
        let maxConH =  containerHeight * 0.15
        let limit = containerHeight + maxConH

        let canInsert = newBottom <= limit

        PIPChatLog(
            """
            CanInsert \(canInsert)
            CurrentBottom:\(currentBottom)
            NewBottom:\(newBottom)
            Limit:\(limit)
            容許超出15%:+\(maxConH)
            """
        )

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
                horizontalSpacing: data.horizontalSpacing, data: data
                     )

            msg.parentMessageID = data.parentID
            msg.segmentIndex = data.segmentIndex


            // 🔑 先確保目前 targetY 是最新
            _ = relayoutTargetsOnly(updateTargetY: true)

            guard canInsertMessage(msg) else {

                phase = .moving
                lastMoveTriggerTime = CACurrentMediaTime()

                PIPChatLog("放不下切換回Move狀態 重新Fade")
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
        // 取得這組還有 alpha > 0 的最下方訊息
        let bottomY  = stackedMessages
               .filter({ $0.alpha > 0 })
               .map { $0.targetY + $0.height + $0.verticalSpacing }
               .max() ?? topMargin




        let conSize = containerHeight * 0.92 - bottomPadding
        PIPChatLog("MaxBottom:\(bottomY) Container:\(conSize)")
        return bottomY  > conSize


    }



    let snapThreshold: CGFloat = 0.2

    // MARK: - Layout + Animation 修正版（可直接替換）
    func layoutTargetsAndStartAnimation() {

        // 🔑 一定要先算 targetY（否則動畫會拉到 0）
        _ = relayoutTargetsOnly(updateTargetY: true)

        rebuildAnimatingGroups()
        fixMoving()

        phase = .moving
        lastMoveTriggerTime = CACurrentMediaTime()

        for msg in stackedMessages where abs(msg.startY - msg.targetY) >= snapThreshold {
            msg.initialStartY = msg.startY
        }


        collectMovingMessages()

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







    private func rebuildAnimatingGroups() {
        // 所有還在移動的訊息
        let movingMessages = stackedMessages
            .filter { $0.alpha > 0 && abs($0.startY - $0.targetY) >= snapThreshold }

        let ordered = movingMessages.sorted {
            if $0.parentMessageID == $1.parentMessageID {
                return $0.segmentIndex < $1.segmentIndex
            }
            return $0.insertionIndex < $1.insertionIndex
        }

        animatingGroups = Dictionary(grouping: ordered, by: { $0.parentMessageID! })
            .values
            .map { $0.sorted { $0.segmentIndex < $1.segmentIndex } }

        // 🔹 確保 animatingMessages 也包含所有還在移動的訊息
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



        // 4️⃣ 動畫
        let now = CACurrentMediaTime()
        let elapsed = now - lastMoveTriggerTime
        lastMoveTriggerTime = now

        var anyStillMoving = false // 用來判斷整組訊息是否都完成移動

        for group in moving {
            // 計算組的移動距離
            guard let firstMsg = group.first else { continue }
            let distance = abs(firstMsg.targetY - firstMsg.startY)
            let moveDuration = max(0.15, min(0.45, distance / 120.0))
            let moveStep = min(elapsed / moveDuration, 1)

            var groupMoving = false // 判斷這組內是否還有訊息在動

            // 組內每條訊息同步移動
            for msg in group {

                if abs(msg.startY - msg.targetY) >= snapThreshold {

                    let newY = msg.startY + (msg.targetY - msg.startY) * moveStep
                    msg.isNew = false
                    msg.startY = newY

                    //PIPChatLog("NewY:\(newY) SY:\(msg.startY) -> \(msg.targetY)")
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

        // ✅ 如果整個動畫都完成
        if !anyStillMoving {
            onMoveFinished()
        }


    }

    private func onMoveFinished() {

        PIPChatLog("MovingOK")


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
        }
    }



    private func findFadeCandidate() -> MessageLayerTuple? {

        // 1️⃣ 只看「穩定、可見、不是新訊息」的 leader
        let leaders = stackedMessages
            .filter { msg in
                msg.alpha > 0 &&
                !msg.isNew &&
                !msg.isFadingOut &&
                abs(msg.startY - msg.targetY) < snapThreshold
            }

        guard !leaders.isEmpty else { return nil }

        // 2️⃣ 找畫面中「最上面」的那一組
        // ⚠️ 一定要用 targetY，不是 startY
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
            PIPService.shared.markDirty()

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

        // 動畫結束，真正移除
        removeMessage(msg)
        fadeCandidate = nil

        _ = relayoutTargetsOnly(updateTargetY: true, changeSY: false)

        rebuildAnimatingGroups()
        // 標記動畫需要更新，但不要重置 targetY
        fixMoving()


        phase = .moving
        lastMoveTriggerTime = CACurrentMediaTime()



    }

    func removeMessage(_ msg:MessageLayerTuple){

        msg.avatar?.removeAllAnimations()
        msg.name?.removeAllAnimations()
        msg.message?.removeAllAnimations()
        msg.gift?.removeAllAnimations()

        msg.avatar?.removeFromSuperlayer()
        msg.name?.removeFromSuperlayer()
        msg.message?.removeFromSuperlayer()
        msg.gift?.removeFromSuperlayer()

        msg.isFadingOut = false



        if let idx = stackedMessages.firstIndex(where: { $0 ===  msg }) {
            stackedMessages.remove(at: idx)
        }

        animatingMessages.removeAll { $0 ===  msg }
        animatingMessages.removeAll { $0.alpha <= 0 }



    }


    private func stopDisplayLink() {



        displayLink?.invalidate()
        displayLink = nil
        phase = .idle

        isAnimating = false




        Task { @MainActor in
            PIPService.shared.isAnimatingMessages = false
            PIPService.shared.startDecayAfterAnimation()
        }

    }


    var isWaitFade = false
    func waitFade() {
        
        guard !isWaitFade else { return }

        isWaitFade = true
        PIPService.shared.waitFade()

    }

    func reloadPending() {
        guard pendingSegments.count > 0 else {
            phase = .moving
            lastMoveTriggerTime = CACurrentMediaTime()

            PIPChatLog("待處理清單已清理完! :\(pendingSegments.count)")
            return

        }


        populateVisibleMessagesIfNeeded()
    }


    private func startFadeAnimation(for msg: MessageLayerTuple) {

        let fadeDuration: CGFloat = LPConfig.shared.MessageFadeTime

        let now = CACurrentMediaTime()
        let elapsed = now - lastFadeTriggerTime
        let fadeStep = min(elapsed / fadeDuration, 1)


//        PIPChatLog(
//            "Fade Step in \(String(describing: msg.name?.string)) : \(String(describing: msg.message?.string)) Time:\(duration) Alpah:\(msg.alpha)"
//        )

        lastFadeTriggerTime = now

        msg.isFadingOut = true

        if msg.alpha > 0 {
            msg.alpha -= fadeStep

            if let avatar = msg.avatar {
                avatar.opacity -= Float(fadeStep)
            }
            if let name = msg.name {
                name.opacity -= Float(fadeStep)
            }
            if let MSG = msg.message {
                MSG.opacity -= Float(fadeStep)
            }
            if let gift = msg.gift {
                gift.opacity -= Float(fadeStep)
            }
            if msg.alpha < 0 { msg.alpha = 0 }

        }


    }


    // MARK: - 每幀動畫
    @objc private func stepAnimationDisplayLink() {

        PIPChatLog(
            "Debug step is doing\nDL step | anim:\(animatingMessages.count) 待處理:\(pendingSegments.count) 容器數量:\(stackedMessages.count) - \(phase)"
        )

        switch phase {
            case .moving:
                animateMoveIfNeeded()


            case .fading:
            stepFade()

            case .idle:
                stopDisplayLink()
            case .waitFading:
                waitFade()
                prepareFade()

            case .pending:
                reloadPending()
            }


    }


    private func layout(msg: MessageLayerTuple, y: CGFloat,x:CGFloat? = nil) {

        let adjustedY = max(y, topMargin)

        msg.adjustedY = adjustedY

        let avatarSizeLocal = msg.avatarSize ?? self.avatarSize
        let giftSizeLocal = msg.giftSize ?? self.giftSize

        let textX = msg.textX

        // Avatar
        msg.avatar?.frame.origin = CGPoint(
            x: textX - avatarSizeLocal,
            y: y
        )



        // Name
        var cursorY = y

        if let nameLayer = msg.name {
            // Name（不再計算）
            let size = msg.cachedNameSize

            nameLayer.frame = CGRect(
                x: textX,
                y: cursorY ,
                width: size.width,
                height: size.height
            )



            cursorY += size.height + msg.verticalSpacing

            // 第一行的 top
            let textCenterY = nameLayer.frame.origin.y + nameLayer.frame.height / 2
            msg.avatar?.frame.origin.y = textCenterY - avatarSizeLocal / 2

        }



        var offSet = 0.0

        // Message
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

        // Gift（不再算 lastLine）

        if let gift = msg.gift,
           let messageLayer = msg.message {

            let minX = messageLayer.frame.minX
            let minY = messageLayer.frame.minY

            let GiftCX = msg.cachedGiftOffsetX
            let GiftCY = msg.cachedGiftOffsetY



//            PIPChatLog(
//                "M:\(String(describing: messageLayer.string)) Mes MinX:\(minX) MinY:\(minY) Gift X:\(GiftCX) Y:\(GiftCY)"
//            )

            gift.frame = CGRect(
                x: minX + GiftCX,
                y: minY + GiftCY,
                width: giftSizeLocal,
                height: giftSizeLocal
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

    // 這裡傳 PIPService 的 debug layer
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

                let user =  "1阿呵呵呵阿呵呵呵阿呵呵呵阿呵呵呵2阿呵呵呵阿3呵呵呵阿呵呵4呵阿呵呵呵阿呵呵呵阿呵呵呵阿5呵呵呵阿呵呵呵阿呵呵呵阿呵呵呵阿呵呵呵測試5"

                let msg =  "1阿呵呵呵阿呵呵呵2阿呵呵呵阿3呵呵呵阿呵呵呵阿呵呵呵阿呵4呵呵阿呵呵呵阿呵呵呵阿呵呵呵5阿呵呵呵阿呵呵呵阿呵呵呵測試6"
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
//            DebugImageViewWrapper(layer: PIPService.shared.debugDisplayLayer)
//                .frame(width: 300, height: 200)
//                .border(Color.red)
            

        }
        .padding()
    }
}
// 這是一個你自訂的內容（聊天室/動畫等）
