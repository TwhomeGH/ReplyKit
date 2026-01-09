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




// MARK: Message Model
final class MessageLayerTuple:Equatable {
    let avatar: CALayer?
    let name: CATextLayer?
    let message: CATextLayer?
    let gift: CALayer?


    var isFadingOut: Bool = false
    var isMoving:Bool = false

    var parentMessageID: UUID? = nil  // 標識同一條長訊息的多個段落
    var segmentIndex: Int = 0         // 這條訊息是第幾段

    var didResolveSize: Bool = false

    var verticalSpacing: CGFloat = 4
    var horizontalSpacing: CGFloat = 6


    var isNew: Bool = false      // 是否新訊息
    var startY: CGFloat = 0      // 動畫起始 y
    var targetY: CGFloat = 0     // 動畫目標 y
    var height: CGFloat = 0      // 訊息總高度

    var overflowHeight: CGFloat?

    // ⚡ 新增支援訊息大小的屬性
    var font: UIFont?             // 訊息字體
    var avatarSize: CGFloat?      // avatar 尺寸
    var giftSize: CGFloat?        // gift 尺寸

    // 透明度控制，用於漸隱
    var alpha: CGFloat = 1.0

    // 🔹 新增快取屬性
    var cachedNameSize: CGSize = .zero
    var cachedMessageSize: CGSize = .zero
    var cachedLastLineWidth: CGFloat = 0


    // ⚡ 主要屬性比較用
    static func == (lhs: MessageLayerTuple, rhs: MessageLayerTuple) -> Bool {
        return lhs === rhs // 使用物件引用判斷是否為同一個實例
    }


    init(avatar: CALayer?, name: CATextLayer?, message: CATextLayer?, gift: CALayer?) {
        self.avatar = avatar
        self.name = name
        self.message = message
        self.gift = gift
    }
}




// MARK: - PIP 訊息組（PiP 專用動畫版）
final class PIPServiceMessages {

    // 滾動與漸隱
    var containerHeight: CGFloat { container.bounds.height }
    var scrollSpeed: CGFloat = 1.5           // 每幀上移的像素
    var fadeOutThreshold: CGFloat { container.bounds.height * 0.05 }
    // 舊訊息漸隱開始的高度

    private var lastFadeTriggerTime: CFTimeInterval = 0
    private let fadeInterval: CFTimeInterval = 1.0



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

    private var isAnyMessageFadingOut: Bool = false
    private var needsRelayoutAfterRemoval = false

    let bottomPadding: CGFloat = 4

    private var safeCanncel: Bool = false

    deinit {

        logTo("Deinit OK")

    }

    func canncel() {
        safeCanncel = true
        logTo("已取消使用")

    }


    var leftPadding: CGFloat = 8

    // Animation
    private var isAnimating = false
    private var displayLink: CADisplayLink?
    private var animationSteps = 15
    private var currentStep = 0

    enum MessageType {
        case primary
        case secondary
    }

    init(size: CGSize) {
        container.frame = CGRect(origin: .zero, size: size)
        container.masksToBounds = true
    }



    private func relayoutTargetsOnly(updateTargetY: Bool = true) {

        let bottomMsgHeight = bottomMessage?.height ?? 0

        // 🔑 1️⃣ 用「目前畫面順序」排序
        let relayoutMessages = stackedMessages
            .filter {
                $0.alpha > 0 &&
                $0.didResolveSize
            }


        var yCursor = topMargin

        for msg in relayoutMessages {

            let overflowHeight = (yCursor + msg.height) - (
                container.bounds.height - bottomMsgHeight - bottomPadding
            )

            msg.overflowHeight = max(overflowHeight, 0)

            if updateTargetY {
                msg.targetY = yCursor

            }
            yCursor += msg.height

        }

        layoutBottomMessage()
    }


    // MARK: - 拆分長訊息生成多個 MessageLayerTuple（支援 avatar/gift 非阻塞下載）
    private func splitLongMessage(
        user: String,
        message: String,
        imgURL: String?,
        giftURL: String?,
        font: UIFont,
        avatarSizeLocal: CGFloat,
        giftSizeLocal: CGFloat,
        verticalSpacing: CGFloat = 8,
        horizontalSpacing: CGFloat = 8
    ) -> [MessageLayerTuple] {

        var tuples: [MessageLayerTuple] = []

        let containerMaxHeight = container.bounds.height - topMargin - bottomPadding // bottomPadding


        let maxNameWidth = container.bounds.width
            - leftPadding * 2
            - avatarSizeLocal
            - horizontalSpacing

        // ⚠️ 用「最保守」的 message 寬度（假設最後一段有 gift）
        let maxMessageWidth = container.bounds.width
            - leftPadding * 2
            - avatarSizeLocal
            - horizontalSpacing
            - giftSizeLocal - 2


        var remainingText = message
        var segmentIndex = 0

        // 預計段數，用於最後一段禮物判斷
        var estimatedSegments: [String] = []

        // 先粗略拆段以計算最後一段
        while !remainingText.isEmpty {
            var fitLength = remainingText.count
            var segmentText = remainingText

            while fitLength > 0 {


                let nameHeight: CGFloat = segmentIndex == 0
                    ? (user as NSString).boundingRect(
                        with: CGSize(width: maxNameWidth, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: [.font: font],
                        context: nil
                      ).height
                    : 0


                let messageHeight = (segmentText as NSString).boundingRect(
                    with: CGSize(width: maxMessageWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font],
                    context: nil
                ).height



                let textBlockHeight = nameHeight + verticalSpacing + messageHeight
                let totalHeight = max(avatarSizeLocal, textBlockHeight) + verticalSpacing

                if totalHeight <= containerMaxHeight { break }

                fitLength -= 1
                segmentText = String(remainingText.prefix(fitLength))
            }

            estimatedSegments.append(segmentText)
            remainingText = String(remainingText.dropFirst(segmentText.count))
        }

        let totalSegments = estimatedSegments.count
        remainingText = message

        let parentID = UUID()

        for segmentText in estimatedSegments {

            let tuple = buildMessageTuple(
                user: user,
                message: segmentText,
                img: segmentIndex == 0 ? nil : nil, // avatarLayer 先設 nil，用 URL 下載
                giftImg: segmentIndex == totalSegments - 1 ? nil : nil, // giftLayer 先設 nil，用 URL 下載
                showAvatar: segmentIndex == 0,
                showName: segmentIndex == 0,
                showMessage: true,
                showGift: segmentIndex == totalSegments - 1,
                font: font,
                avatarSizeLocal: avatarSizeLocal,
                giftSizeLocal: giftSizeLocal,
                verticalSpacing: verticalSpacing,
                horizontalSpacing: horizontalSpacing
            )

            tuple.segmentIndex = segmentIndex

            tuple.parentMessageID = parentID
            tuples.append(tuple)

            // 非阻塞下載 avatar（只在第一段）
            if let imgURL = imgURL, segmentIndex == 0 {
                PIPChatLog("IMGURL:\(imgURL)")

                Task {
                    await PiPImageCache.shared
                        .loadImage(urlString: imgURL) { image in
                        tuple.avatar?.contents = image?.cgImage
                    }
                }

            }

            // 非阻塞下載 gift（只在最後一段）
            if let giftURL = giftURL, segmentIndex == totalSegments - 1 {
                PIPChatLog("GiftURL:\(giftURL)")

                Task {
                 await   PiPImageCache.shared
                        .loadImage(urlString: giftURL) { image in
                            tuple.gift?.contents = image?.cgImage

                        }
                }
            }

            PIPChatLog(
                "Split segment \(segmentIndex): height=\(tuple.height), text='\(segmentText)'"
            )
            segmentIndex += 1
        }

        return tuples
    }

    // MARK: - Build Message Tuple（抽出來重用）
    func buildMessageTuple(
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

        // 🔹 同步計算高度
        let maxNameWidth = container.bounds.width
            - leftPadding * 2
            - avatarSizeLocal
        - tuple.horizontalSpacing

        let maxMessageWidth = container.bounds.width
            - leftPadding * 2
            - avatarSizeLocal
        - tuple.horizontalSpacing
            - (giftLayer != nil ? giftSizeLocal + 2 : 0)

        let nameHeight = showName
            ? (user as NSString).boundingRect(
                with: CGSize(width: maxNameWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            ).height
            : 0

        let messageHeight = (message as NSString).boundingRect(
            with: CGSize(width: maxMessageWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height

        tuple.cachedNameSize = CGSize(width: maxNameWidth, height: nameHeight)
        tuple.cachedMessageSize = CGSize(width: maxMessageWidth, height: messageHeight)


        // 計算最後一行文字寬度（用 constrained width 模擬）
        let lines = message.split(separator: "\n")
        let lastLine = String(lines.last ?? "")

        let lastLineWidth = (lastLine as NSString).boundingRect(
            with: CGSize(width: maxMessageWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).width

        tuple.cachedLastLineWidth = lastLineWidth


        let textBlockHeight = nameHeight + tuple.verticalSpacing + messageHeight
        tuple.height = max(avatarSizeLocal, textBlockHeight) + tuple.verticalSpacing
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

            let fontSize: CGFloat = (type == .primary) ? 15 : 10
            let avatarSizeLocal: CGFloat = (type == .primary) ? 20 : 18
            let giftSizeLocal: CGFloat = (type == .primary) ? 20 : 18
            let font = UIFont.systemFont(ofSize: fontSize)

            // secondary 不 chunk
            if type == .secondary {

                    let tuple = self.buildMessageTuple(
                        user: user,
                        message: message,
                        img: nil,
                        giftImg: nil,
                        showAvatar: true,
                        showName: true,
                        showGift: true,
                        font: font,
                        avatarSizeLocal: avatarSizeLocal,
                        giftSizeLocal: giftSizeLocal,
                        verticalSpacing: 4,
                        horizontalSpacing: 6
                    )



                    self.replaceBottomMessage(tuple)



                // 2️⃣ 非阻塞下載圖片，下載完成再更新 tuple
                if let imgURL = imgURL {
                    Task {
                     await PiPImageCache.shared.loadImage(urlString: imgURL) { image in
                            tuple.avatar?.contents = image?.cgImage
                        }
                    }
                }

                if let giftURL = giftURL {
                    Task {
                       await PiPImageCache.shared.loadImage(urlString: giftURL) { image in
                            tuple.gift?.contents = image?.cgImage
                        }
                    }
                }

                return
            }



        DispatchQueue.global(qos: .userInitiated).async {

            let segments = self.splitLongMessage(
                user: user,
                message: message,
                imgURL:imgURL,
                giftURL: giftURL,
                font: font,
                avatarSizeLocal: avatarSizeLocal,
                giftSizeLocal: giftSizeLocal
            )
            DispatchQueue.main.async {
                for i in segments {
                    PIPChatLog("SE:\(String(describing: i.message))")
                }
                self.stackedMessages.append(contentsOf: segments)
                self.layoutTargetsAndStartAnimation()
            }
        }





    }


    private func layoutBottomMessage() {
        guard let msg = bottomMessage, (msg.isFadingOut || isAnimating) else { return }

        //let y = bottomPadding
        let y = container.bounds.height - msg.height - bottomPadding
        //let x = 80.0

        PIPChatLog(
            "Debug Bottom? \(String(describing: msg.message?.string)) \(String(describing: msg.message?.opacity))"
        )
        layout(msg: msg, y: y)
    }

    private func replaceBottomMessage(_ newMsg: MessageLayerTuple) {

        // 移除舊的
        if let old = bottomMessage {
            old.avatar?.removeFromSuperlayer()
            old.name?.removeFromSuperlayer()
            old.message?.removeFromSuperlayer()
            old.gift?.removeFromSuperlayer()
        }

        bottomMessage = newMsg

        layoutBottomMessage()
        PIPService.shared.markDirty()

    }





    func IshasOverFlow() -> Bool {
        stackedMessages.contains { msg in

            PIPChatLog(
                "MSG:\(String(describing: msg.message?.string)) \(msg.startY)-\(msg.targetY) H:\(msg.height) TH:\(msg.targetY + msg.height) "
            )
            let bottomY = msg.targetY + msg.height

            return bottomY > container.bounds.height - bottomPadding
        }


    }

    // MARK: - Layout + Animation 修正版（可直接替換）
    func layoutTargetsAndStartAnimation() {

        // 🔑 一定要先算 targetY（否則動畫會拉到 0）
        relayoutTargetsOnly(updateTargetY: true)

        // Debug 輸出
        PIPChatLog("--- layoutTargets ---")


        // 將 stackedMessages 按 targetY 排序，從上到下
        let sortedStack = stackedMessages
            .filter { $0.alpha > 0 }

        //var lastY = topMargin

        for msg in sortedStack {
            // 新訊息且還沒在 animatingMessages
            if msg.isNew && !animatingMessages.contains(msg) {

                // 如果 startY 還是 0，初始化到 container 外面
                if msg.startY == 0 {
                    msg.startY = container.bounds.height + msg.height
                }

                animatingMessages.append(msg)
            }
        }



        // 啟動 displayLink
        if displayLink == nil {
            displayLink = CADisplayLink(target: self, selector: #selector(stepAnimationDisplayLink))
            displayLink?.add(to: .main, forMode: .common)
            isAnimating = true
        }


    }



    func showBottom(_ shouldHideBottom:Bool = false) {
        if let bottom = bottomMessage {

            PIPChatLog(
                "bottomMessage startY:\(String(describing: bottom.avatar?.frame.origin.y)) H:\(bottom.height) IsShow:\(shouldHideBottom)"
            )

            let targetOpacity: Float = shouldHideBottom ? 0.0 : 1.0

            bottom.avatar?.opacity = targetOpacity
            bottom.name?.opacity = targetOpacity
            bottom.message?.opacity = targetOpacity
            bottom.gift?.opacity = targetOpacity
        }

    }


    let snapThreshold: CGFloat = 0.5

    // MARK: - 每幀動畫
    @objc private func stepAnimationDisplayLink() {



        PIPChatLog("Debug step is doing \(Date().formatted())")

        // 2️⃣ 更新 animatingMessages 位置
        for msg in animatingMessages {
            let distance = msg.targetY - msg.startY
            if abs(distance) >= snapThreshold {
                msg.startY += distance * 0.2
            } else {
                msg.startY = msg.targetY
                msg.isNew = false
            }
            layout(msg: msg, y: msg.startY)
        }

        // 3️⃣ Fade 最上方舊訊息，保留最下面兩條



        let now = CACurrentMediaTime()


        // 2️⃣ 如果有超出，就淡出最前面一條還在可視範圍的訊息
        if IshasOverFlow() && !isAnyMessageFadingOut , let firstMsg = stackedMessages
            .filter({ $0.targetY + $0.height > fadeOutThreshold })
            .min(
            by: { $0.targetY < $1.targetY
            }){

            PIPChatLog("firstMsg:\(String(describing: firstMsg.message?.string))")



            if firstMsg.isMoving == false {

                // 第一次觸發時記錄時間
                if lastFadeTriggerTime == 0 {
                    lastFadeTriggerTime = now
                }

                // 達到延遲時間才開始淡出
                if now - lastFadeTriggerTime >= fadeInterval {

                    PIPChatLog("等待淡出")
                    firstMsg.isFadingOut = true
                    isAnyMessageFadingOut = true
                    lastFadeTriggerTime = now
                }

            }

            showBottom(true)
        } else {
            showBottom(false)
        }

        for msg in stackedMessages where msg.isFadingOut {
            msg.alpha -= 0.04
            msg.alpha = max(0, msg.alpha)
            msg.avatar?.opacity = Float(msg.alpha)
            msg.name?.opacity = Float(msg.alpha)
            msg.message?.opacity = Float(msg.alpha)
            msg.gift?.opacity = Float(msg.alpha)

        }



        var i = 0
        while i < stackedMessages.count {
            let msg = stackedMessages[i]
            if msg.alpha <= 0.01 {
                msg.avatar?.removeFromSuperlayer()
                msg.name?.removeFromSuperlayer()
                msg.message?.removeFromSuperlayer()
                msg.gift?.removeFromSuperlayer()

                animatingMessages.removeAll { $0 === msg }
                stackedMessages.remove(at: i)

                relayoutTargetsOnly()
                isAnyMessageFadingOut = false

            } else {
                i += 1
            }
        }


        relayoutTargetsOnly(updateTargetY: false)


        // 5️⃣ 動畫完成判斷
        let hasMovingOrFading = stackedMessages.contains { msg in


            let isMoving = abs(msg.startY - msg.targetY) >= snapThreshold

            let isFading = msg.alpha > 0.01 && msg.alpha < 1.0

            PIPChatLog(
                "hasM:\(String(describing: msg.message?.string)) TY:\(msg.targetY) SY:\(msg.startY) TY-SY\(msg.startY - msg.targetY) snap:\(snapThreshold) alpha:\(msg.alpha) Moving:\(isMoving) Fading:\(isFading)"
            )

            msg.isMoving = isMoving

            return isMoving || isFading

        }


        let isWaitingForFadeDelay = IshasOverFlow() || !isAnyMessageFadingOut &&
            lastFadeTriggerTime != 0 &&
        now - lastFadeTriggerTime < fadeInterval  // fadeDelay

        PIPChatLog("hasMoving?\(hasMovingOrFading) - isWaitFor:\(isWaitingForFadeDelay) NowWait:\(now-lastFadeTriggerTime) < \(fadeInterval)?")


        if !hasMovingOrFading && !isWaitingForFadeDelay || safeCanncel {

            for msg in animatingMessages {
                  msg.startY = msg.targetY
                   layout(msg: msg, y: msg.targetY)
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

        layoutBottomMessage()

        // 6️⃣ needsRelayoutAfterRemoval 只做 layout，不重啟 displayLink
        if needsRelayoutAfterRemoval {
            needsRelayoutAfterRemoval = false
            relayoutTargetsOnly(updateTargetY: true)

        }


        // 7️⃣ 更新 dirty 狀態

        if now - lastDirtyTime > 1.0 / 20 {
            lastDirtyTime = now
            PIPService.shared.markDirty()
            PIPService.shared.isAnimatingMessages = true
        }
    }

    private func layout(msg: MessageLayerTuple, y: CGFloat,x:CGFloat? = nil) {


        let adjustedY = y

        let avatarSizeLocal = msg.avatarSize ?? self.avatarSize
        let giftSizeLocal = msg.giftSize ?? self.giftSize


        var textX = leftPadding + avatarSizeLocal + msg.horizontalSpacing

        if let x = x {
            textX = x
        }

        // Avatar
        msg.avatar?.frame.origin.y = adjustedY
        msg.avatar?.frame.origin.x = textX - avatarSizeLocal
        PIPChatLog("CNameWidth:\(msg.cachedNameSize.width)")



        // Name（不再計算）
        let nameSize = msg.cachedNameSize

        msg.name?.frame = CGRect(
            x: textX,
            y: adjustedY,
            width: container.bounds.width - textX - leftPadding,
            height: nameSize.height
        )


        if let nameLayer = msg.name  {

            // 第一行的 top
            let textCenterY = nameLayer.frame.origin.y + nameLayer.frame.height / 2
            msg.avatar?.frame.origin.y = textCenterY - avatarSizeLocal / 2

        }


        // Message（不再計算）
        let messageY: CGFloat

        if let nameLayer = msg.name {
            messageY = nameLayer.frame.maxY + msg.verticalSpacing
        } else {
            // 👇 沒有 name，就從 targetY 本身開始
            messageY = msg.targetY
        }


        let messageSize = msg.cachedMessageSize
        msg.message?.frame = CGRect(
            x: textX,
            y: messageY,
            width: container.bounds.width - textX - leftPadding,
            height: messageSize.height
        )

        // Gift（不再算 lastLine）

        if let gift = msg.gift,
           let messageLayer = msg.message {


            let messageBottomY = messageLayer.frame.maxY
            let lastLineCenterY = messageBottomY - lineHeight / 2

            gift.frame = CGRect(
                x: messageLayer.frame.origin.x + msg.cachedLastLineWidth + 2,
                y: lastLineCenterY - giftSizeLocal / 2,
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
    if LPConfig.shared.PIPChatLog {
        sendlog(title:"[PIP_Chat]",message: message)
    }
}

struct DebugImageViewWrapper: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)

        // 設定 debugImageView
        PIPService.shared.setupDebugImageView(in: container,
                                              frame: CGRect(x: 0, y: 0, width: 150, height: 100))
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct PIPView: View {

    // 狀態管理哪個 PiP 正在啟用
    @State private var isChatPiPActive = false
    @State private var isTestPiPActive = false

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
