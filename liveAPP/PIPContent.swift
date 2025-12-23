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




final class PiPImageCache {
    static let shared = PiPImageCache()
    private let cache = NSCache<NSString, UIImage>()

    // ✅ 新增：追蹤正在下載的 URL
    private var loadingTasks: [String: [(UIImage?) -> Void]] = [:]
    private let queue = DispatchQueue(label: "PiPImageCacheQueue")


    private init() {
        cache.countLimit = 50         // 最多存 50 張圖片
        cache.totalCostLimit = 20 * 1024 * 1024 // 最大約 20 MB
    }

    func image(for url: String) -> UIImage? {
        logTo("Has Cache Img")
        return cache.object(forKey: url as NSString)
    }

    func store(_ image: UIImage, for url: String) {
        logTo("Set Cache Img")
        cache.setObject(image, forKey: url as NSString)
    }

    // ✅ 新增：安全加載圖片方法
    func load(urlString: String, completion: @escaping (UIImage?) -> Void) {

        if let img = image(for: urlString) {
            DispatchQueue.main.async {
                completion(img)
            }
            return
        }

        queue.async {
            if self.loadingTasks[urlString] != nil {
                self.loadingTasks[urlString]?.append(completion)
                return
            }

            self.loadingTasks[urlString] = [completion]

            guard let url = URL(string: urlString) else {
                self.callCompletions(for: urlString, with: nil)
                return
            }

            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                var image: UIImage?
                if let data = data {
                    image = UIImage(data: data)
                    if let img = image {
                        self?.store(img, for: urlString)
                    }
                }
                self?.callCompletions(for: urlString, with: image)
            }.resume()
        }
    }

    private func callCompletions(for urlString: String, with image: UIImage?) {
        queue.async {
            guard let completions = self.loadingTasks[urlString] else { return }
            self.loadingTasks[urlString] = nil

            DispatchQueue.main.async {
                completions.forEach { $0(image) }
            }
        }
    }


}

extension URL {
    /// 移除 query（?xxx=yyy），只保留 base URL
    var deletingQuery: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.query = nil
        return components.url ?? self
    }
}



// MARK: Message Model
final class MessageLayerTuple:Equatable {
    let avatar: CALayer
    let name: CATextLayer
    let message: CATextLayer
    let gift: CALayer?

    var didResolveSize: Bool = false

    var verticalSpacing: CGFloat = 4
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


    init(avatar: CALayer, name: CATextLayer, message: CATextLayer, gift: CALayer?) {
        self.avatar = avatar
        self.name = name
        self.message = message
        self.gift = gift
    }
}




func PIPChatLog(_ message:String){
    if LPConfig.shared.PIPChatLog {
        sendlog(title:"[PIP_Chat]",message: message)
    }
}

// MARK: - PIP 訊息組（PiP 專用動畫版）
final class PIPServiceMessages {

    // 滾動與漸隱
    var containerHeight: CGFloat { container.bounds.height }
    var scrollSpeed: CGFloat = 1.5           // 每幀上移的像素
    var fadeOutThreshold: CGFloat { container.bounds.height * 0.05 }
    // 舊訊息漸隱開始的高度


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


    var verticalSpacing: CGFloat = 4
    var horizontalSpacing: CGFloat = 6
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



    private func relayoutTargetsOnly() {

        let bottomPadding: CGFloat = 8
        let bottomMsgHeight = bottomMessage?.height ?? 0

        // 🔑 1️⃣ 用「目前畫面順序」排序
        let relayoutMessages = stackedMessages
            .filter {
                $0.alpha > 0 &&
                $0.didResolveSize
            }
            .sorted {
                // 舊訊息先排，新的訊息排最後
                if $0.isNew != $1.isNew {
                    return !$0.isNew
                }
                return $0.targetY < $1.targetY

            }


        var yCursor = topMargin

        for msg in relayoutMessages {

            let overflowHeight = (yCursor + msg.height) - (
                container.bounds.height - bottomMsgHeight - bottomPadding
            )

            msg.overflowHeight = max(overflowHeight, 0)

            msg.targetY = min(
                yCursor,
                container.bounds.height - bottomMsgHeight - bottomPadding - msg.height
            )

            yCursor += msg.height + msg.verticalSpacing
        }

        layoutBottomMessage()
    }

    // MARK: - Build Message Tuple（抽出來重用）
    func buildMessageTuple(
        user: String,
        message: String,
        img: UIImage?,
        giftImg: UIImage?,
        showAvatar: Bool,
        showName: Bool,
        font: UIFont,
        avatarSizeLocal: CGFloat,
        giftSizeLocal: CGFloat
    ) -> MessageLayerTuple {

        // Avatar
        let avatarLayer = CALayer()
        avatarLayer.contents = img?.cgImage
        avatarLayer.contentsGravity = .resizeAspectFill
        avatarLayer.frame = CGRect(
            x: leftPadding,
            y: container.bounds.height,
            width: avatarSizeLocal,
            height: avatarSizeLocal
        )
        avatarLayer.opacity = showAvatar ? 1 : 0
        container.addSublayer(avatarLayer)

        // Name
        let nameLayer = CATextLayer()
        nameLayer.string = user
        nameLayer.font = font
        nameLayer.fontSize = font.pointSize
        nameLayer.foregroundColor = UIColor.white.cgColor
        nameLayer.contentsScale = UIScreen.main.scale
        nameLayer.isWrapped = true
        nameLayer.alignmentMode = .left
        nameLayer.opacity = showName ? 1 : 0
        container.addSublayer(nameLayer)

        // Message
        let messageLayer = CATextLayer()
        messageLayer.string = message
        messageLayer.font = font
        messageLayer.fontSize = font.pointSize
        messageLayer.foregroundColor = UIColor.white.cgColor
        messageLayer.contentsScale = UIScreen.main.scale
        messageLayer.isWrapped = true
        messageLayer.alignmentMode = .left
        container.addSublayer(messageLayer)

        // Gift
        var giftLayer: CALayer?
        if let gift = giftImg {
            let layer = CALayer()
            layer.contents = gift.cgImage
            layer.contentsGravity = .resizeAspect
            container.addSublayer(layer)
            giftLayer = layer
        }

        let tuple = MessageLayerTuple(
            avatar: avatarLayer,
            name: nameLayer,
            message: messageLayer,
            gift: giftLayer
        )

        tuple.font = font
        tuple.avatarSize = avatarSizeLocal
        tuple.giftSize = giftSizeLocal
        tuple.verticalSpacing = 4
        tuple.isNew = true
        tuple.alpha = 1.0

        // 先計算高度（layout 會再修正）
        let maxNameWidth = container.bounds.width
            - leftPadding * 2
            - avatarSizeLocal
            - horizontalSpacing


        Task.detached { [weak self] in
            guard let self = self else { return }


            // 背景線程計算高度

            let nameHeight = showName
            ? (user as NSString).boundingRect(
                with: CGSize(width: maxNameWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            ).size
            : .zero



            let maxMessageWidth = container.bounds.width
            - leftPadding * 2
            - avatarSizeLocal
            - horizontalSpacing
            - (giftLayer != nil ? giftSizeLocal + 2 : 0)

            let messageHeight = (message as NSString).boundingRect(
                with: CGSize(width: maxMessageWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            ).size


            tuple.cachedNameSize = CGSize(width: maxNameWidth, height: nameHeight.height)
            tuple.cachedMessageSize = CGSize(width: maxMessageWidth, height: messageHeight.height)
            tuple.cachedLastLineWidth = messageHeight.width  // 用於 gift 對齊

            let textBlockHeight = nameHeight.height + tuple.verticalSpacing + messageHeight.height


            await MainActor.run {

                tuple.height = max(avatarSizeLocal, textBlockHeight) + tuple.verticalSpacing

                if !tuple.didResolveSize {
                    tuple.didResolveSize = true
                    // 🔑 尺寸第一次完成，重新計算所有 targetY
                    self.relayoutTargetsOnly()
                }



            }

        }

        return tuple
    }

    private var lastDirtyTime: CFTimeInterval = 0





    // MARK: - Add Message（Chunk 修正版，可直接替換）
    func addMessage(
        user: String,
        message: String,
        imgURL: String? = nil,
        giftURL: String? = nil,
        isMain: Bool = true
    ) {

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

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
                        font: font,
                        avatarSizeLocal: avatarSizeLocal,
                        giftSizeLocal: giftSizeLocal
                    )


                await MainActor.run {
                    self.replaceBottomMessage(tuple)

                }

                // 2️⃣ 非阻塞下載圖片，下載完成再更新 tuple
                if let imgURL = imgURL {
                    PiPImageCache.shared.load(urlString: imgURL) { image in
                        tuple.avatar.contents = image?.cgImage
                    }
                }

                if let giftURL = giftURL {
                    PiPImageCache.shared.load(urlString: giftURL) { image in
                        tuple.gift?.contents = image?.cgImage
                    }
                }

                return
            }




            let tuple = self.buildMessageTuple(
                user: user,
                message: message,
                img: nil,
                giftImg: nil,
                showAvatar: true,
                showName: true,
                font: font,
                avatarSizeLocal: avatarSizeLocal,
                giftSizeLocal: giftSizeLocal
            )

            await MainActor.run {
                self.stackedMessages.append(tuple)
                self.layoutTargetsAndStartAnimation()
            }
            // 2️⃣ 非阻塞下載圖片，下載完成再更新 tuple
            if let imgURL = imgURL {
                PiPImageCache.shared.load(urlString: imgURL) { image in
                    tuple.avatar.contents = image?.cgImage
                }
            }

            if let giftURL = giftURL {
                PiPImageCache.shared.load(urlString: giftURL) { image in
                    tuple.gift?.contents = image?.cgImage
                }
            }

        }

    }


    private func layoutBottomMessage() {
        guard let msg = bottomMessage else { return }

        let bottomPadding: CGFloat = 8
        let y = container.bounds.height - msg.height - bottomPadding

        layout(msg: msg, y: y)
    }

    private func replaceBottomMessage(_ newMsg: MessageLayerTuple) {

        // 移除舊的
        if let old = bottomMessage {
            old.avatar.removeFromSuperlayer()
            old.name.removeFromSuperlayer()
            old.message.removeFromSuperlayer()
            old.gift?.removeFromSuperlayer()
        }

        bottomMessage = newMsg

    }




    let minVisibleCount = 2

    private var needsRelayoutAfterRemoval = false

    // MARK: - Layout + Animation 修正版（可直接替換）
    func layoutTargetsAndStartAnimation() {

        // 🔑 唯一一次 targetY 計算
        relayoutTargetsOnly()

        // Debug 輸出

        PIPChatLog("--- layoutTargets ---")


        // 將 stackedMessages 按 targetY 排序，從上到下
        let sortedStack = stackedMessages
            .filter { $0.alpha > 0 }
            .sorted { $0.targetY < $1.targetY }

        var lastY = topMargin

        for msg in sortedStack {

            // 🔑 新訊息還沒在 animatingMessages 就加入
            if msg.isNew && !animatingMessages.contains(msg) {
                animatingMessages.append(msg)
                // 新訊息從上一個 targetY 開始動畫
                msg.startY = lastY
            }

            PIPChatLog("lastY:\(lastY)")
            lastY = msg.targetY + msg.height + msg.verticalSpacing

        }


        // 啟動 displayLink
        if displayLink == nil {
            displayLink = CADisplayLink(target: self, selector: #selector(stepAnimationDisplayLink))
            displayLink?.add(to: .main, forMode: .common)
            isAnimating = true
        }


        if let bottom = bottomMessage {
            PIPChatLog("bottomMessage startY:\(bottom.avatar.frame.origin.y)")
        }

    }


    // MARK: - 每幀動畫
    @objc private func stepAnimationDisplayLink() {

        // 動畫每幀滑動
        let snapThreshold: CGFloat = 0.6

        // 確保 animatingMessages 包含所有 isNew 訊息
        let newMessages = stackedMessages
            .filter { $0.isNew && !animatingMessages.contains($0) }
            .sorted { $0.targetY < $1.targetY }

        animatingMessages.append(contentsOf: newMessages)


        for msg in animatingMessages {
            let distance = msg.targetY - msg.startY

            PIPChatLog("distance:\(abs(distance)) - snap:\(snapThreshold)")
            if abs(distance) >= snapThreshold {

                msg.startY += distance * 0.2
                layout(msg: msg, y: msg.startY)

            } else {

                msg.startY = msg.targetY
                layout(msg: msg, y: msg.startY)
                msg.isNew = false


            }
        }

        //  清理已經到位動畫
        animatingMessages.removeAll {
            abs($0.startY - $0.targetY) < snapThreshold
        }



        // Fade 超出底部訊息區的最上方訊息
        // 逐塊判斷 fade，每塊 alpha 獨立

        PIPChatLog("STACK:\(stackedMessages.count) ")

        for (i,msg) in stackedMessages
            .enumerated() where msg.alpha > 0 {

            PIPChatLog(
                "EStack[\(i)] [\(String(describing: msg.message.string))] alpha:\(msg.alpha) startY:\(msg.startY) targetY:\(msg.targetY) isNew:\(msg.isNew)"
            )
        }


        let fadeThreshold = topMargin + 1

        let visibleMessages = stackedMessages
            .filter { $0.alpha > 0 && !$0.isNew && $0 !== bottomMessage }
            .sorted { $0.startY < $1.startY } // 從上到下，最上面舊訊息先 fade



        for (i,msg) in visibleMessages.enumerated() where msg.alpha > 0 && !msg.isNew {


            PIPChatLog(
                "stack[\(i)] [\(String(describing: msg.message.string))] alpha:\(msg.alpha) startY:\(msg.startY) targetY:\(msg.targetY)"
            )

            let canFade = stackedMessages.count > minVisibleCount

            PIPChatLog(
                "SSC:\(stackedMessages.count) \(String(describing: msg.message.string)) canFade:\(canFade) \(msg.startY) - \(fadeThreshold)"
            )


            if canFade && msg.startY <= fadeThreshold {

                msg.alpha -= 0.04
                if msg.alpha < 0.01 {
                    msg.alpha = 0
                }

                msg.avatar.opacity = Float(msg.alpha)
                msg.name.opacity = Float(msg.alpha)
                msg.message.opacity = Float(msg.alpha)
                msg.gift?.opacity = Float(msg.alpha)
            }
        }



        // 刪除完全透明訊息
        stackedMessages.removeAll { msg in
            guard msg.alpha <= 0 else { return false }

            msg.avatar.removeFromSuperlayer()
            msg.name.removeFromSuperlayer()
            msg.message.removeFromSuperlayer()
            msg.gift?.removeFromSuperlayer()

            animatingMessages.removeAll { $0 === msg }

            needsRelayoutAfterRemoval = true

            return true
        }


        // 動畫完成判斷
        let hasAnimatingMessages = !animatingMessages.isEmpty

        let hasMovingMessages = stackedMessages.contains {
            $0.alpha > 0 &&
            abs($0.startY - $0.targetY) >= snapThreshold
        }



        let hasFadingMessages = stackedMessages.contains { msg in

            let isFading = msg.alpha > 0 && msg.alpha < 1.0 && !msg.isNew

            if isFading {
                PIPChatLog("🟡 fading alpha = \(msg.alpha)")
            }
            return isFading
        }



        PIPChatLog("hasA:\(hasAnimatingMessages) hasFM:\(hasMovingMessages) hasF:\(hasFadingMessages)")




        if !hasAnimatingMessages && !hasMovingMessages && !hasFadingMessages {

            displayLink?.invalidate()
            displayLink = nil

            isAnimating = false

            animatingMessages.forEach { $0.isNew = false }

            Task  { @MainActor in
                PIPService.shared.isAnimatingMessages = false
                PIPService.shared.startDecayAfterAnimation()
            }
        }

        if needsRelayoutAfterRemoval {
            needsRelayoutAfterRemoval = false
            relayoutTargetsOnly()

            // 2️⃣ 讓剩下的訊息進入動畫狀態，並確保舊訊息先淡出
            let remaining = stackedMessages
                .filter {
                    $0.alpha > 0 &&
                    $0 !== bottomMessage &&
                    !animatingMessages.contains($0) &&
                    $0.startY > fadeThreshold
                }
                    .sorted { $0.targetY > $1.targetY }  // 依 startY 排序，舊訊息先加入


            animatingMessages.append(contentsOf: remaining)

                // 3️⃣ 確保 displayLink 還活著
            if displayLink == nil {
                displayLink = CADisplayLink(
                    target: self,
                    selector: #selector(stepAnimationDisplayLink)
                )
                displayLink?.add(to: .main, forMode: .common)
                isAnimating = true
            }

        }

        // Debug: 每幀輸出 animatingMessages 狀態
        PIPChatLog("--- stepAnimation ---")
        for (i, msg) in animatingMessages.enumerated() {
            PIPChatLog(
                "animating[\(i)] [\(String(describing: msg.message.string))] alpha:\(msg.alpha) startY:\(msg.startY) targetY:\(msg.targetY)"
            )
        }

        let now = CACurrentMediaTime()
        if now - lastDirtyTime > 1.0 / 20 {
            lastDirtyTime = now
            PIPService.shared.markDirty()
            PIPService.shared.isAnimatingMessages = true
        }


    }


    private func layout(msg: MessageLayerTuple, y: CGFloat) {

        var adjustedY = y
        if let overflow = msg.overflowHeight {
            adjustedY -= overflow
        }

        let avatarSizeLocal = msg.avatarSize ?? self.avatarSize
        let giftSizeLocal = msg.giftSize ?? self.giftSize

        // Avatar
        msg.avatar.frame.origin.y = adjustedY

        let textX = leftPadding + avatarSizeLocal + horizontalSpacing

        // Name（不再計算）
        let nameSize = msg.cachedNameSize
        msg.name.frame = CGRect(
            x: textX,
            y: adjustedY,
            width: container.bounds.width - textX - leftPadding,
            height: nameSize.height
        )

        // Message（不再計算）
        let messageY = msg.name.frame.maxY + msg.verticalSpacing
        let messageSize = msg.cachedMessageSize
        msg.message.frame = CGRect(
            x: textX,
            y: messageY,
            width: container.bounds.width - textX - leftPadding,
            height: messageSize.height
        )

        // Gift（不再算 lastLine）
        if let gift = msg.gift {
            gift.frame = CGRect(
                x: msg.message.frame.origin.x + msg.cachedLastLineWidth + 2,
                y: msg.message.frame.midY - giftSizeLocal / 2,
                width: giftSizeLocal,
                height: giftSizeLocal
            )
        }

        // Height（已固定，不再算）
        // ❌ msg.height = ...
        // ✅ 什麼都不用做
    }
    private func easeOutCubic(_ t: Double) -> Double {
        1 - pow(1 - t, 3)
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

                PIPService.shared.addMessage(user: user, msg: msg,imgURL: img)

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
