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

    var verticalSpacing: CGFloat = 4
    var isNew: Bool = false      // 是否新訊息
    var startY: CGFloat = 0      // 動畫起始 y
    var targetY: CGFloat = 0     // 動畫目標 y
    var height: CGFloat = 0      // 訊息總高度

    // ⚡ 新增支援訊息大小的屬性
    var font: UIFont?             // 訊息字體
    var avatarSize: CGFloat?      // avatar 尺寸
    var giftSize: CGFloat?        // gift 尺寸

    // 透明度控制，用於漸隱
    var alpha: CGFloat = 1.0

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


// MARK: - PIP 訊息組（PiP 專用動畫版）
final class PIPServiceMessages {

    // 滾動與漸隱
    var containerHeight: CGFloat { container.bounds.height }
    var scrollSpeed: CGFloat = 1.5           // 每幀上移的像素
    var fadeOutThreshold: CGFloat { container.bounds.height * 0.05 }
    // 舊訊息漸隱開始的高度


    // MARK: - Properties
    let container = CALayer()
    private var stackedMessages: [MessageLayerTuple] = []   // 一般聊天
    private var bottomMessage: MessageLayerTuple?           // 底部固定

    private var animatingMessages: [MessageLayerTuple] = []

    var font: UIFont = .systemFont(ofSize: 16)
    var lineHeight: CGFloat = 20
    var avatarSize: CGFloat = 28
    var giftSize: CGFloat = 28

    var topMargin: CGFloat {
        max(65, container.bounds.height * 0.18)
    }

    // 從底部往上堆疊，保留 topMargin
    var visible: [MessageLayerTuple] = []

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


    // MARK: - Build Message Tuple（抽出來重用）
    private func buildMessageTuple(
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

        let nameHeight = showName
            ? (user as NSString).boundingRect(
                with: CGSize(width: maxNameWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            ).height
            : 0

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
        ).height

        let textBlockHeight = nameHeight + tuple.verticalSpacing + messageHeight
        tuple.height = max(avatarSizeLocal, textBlockHeight) + tuple.verticalSpacing

        return tuple
    }

    private var lastDirtyTime: CFTimeInterval = 0


    // MARK: 切分訊息 如果太長
    private func splitMessageIntoChunks(
        message: String,
        font: UIFont,
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> [String] {

        var result: [String] = []
        var current = ""

        let lines = message.components(separatedBy: "\n")

        for line in lines {
            let test = current.isEmpty ? line : current + "\n" + line

            let height = (test as NSString).boundingRect(
                with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            ).height

            if height > maxHeight {
                if !current.isEmpty {
                    result.append(current)
                    current = line
                } else {
                    result.append(line)
                }
            } else {
                current = test
            }
        }

        if !current.isEmpty {
            result.append(current)
        }

        return result
    }



    // MARK: - Add Message（Chunk 修正版，可直接替換）
    func addMessage(
        user: String,
        message: String,
        img: UIImage? = nil,
        giftImg: UIImage? = nil,
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
                await MainActor.run {
                    let tuple = self.buildMessageTuple(
                        user: user,
                        message: message,
                        img: img,
                        giftImg: giftImg,
                        showAvatar: true,
                        showName: true,
                        font: font,
                        avatarSizeLocal: avatarSizeLocal,
                        giftSizeLocal: giftSizeLocal
                    )
                    self.replaceBottomMessage(tuple)
                }
                return
            }

            let maxMessageWidth =
                self.container.bounds.width
                - self.leftPadding * 2
                - avatarSizeLocal
                - self.horizontalSpacing
                - (giftImg != nil ? giftSizeLocal + 2 : 0)

            let maxChunkHeight =
                self.container.bounds.height
                - self.topMargin
                - (self.bottomMessage?.height ?? 0)
                - 8
                - avatarSizeLocal

            let chunks = self.splitMessageIntoChunks(
                message: message,
                font: font,
                maxWidth: maxMessageWidth,
                maxHeight: maxChunkHeight
            )

            await MainActor.run {
                for (index, chunk) in chunks.enumerated() {
                    let tuple = self.buildMessageTuple(
                        user: user,
                        message: chunk,
                        img: img,
                        giftImg: giftImg,
                        showAvatar: index == 0,
                        showName: index == 0,
                        font: font,
                        avatarSizeLocal: avatarSizeLocal,
                        giftSizeLocal: giftSizeLocal
                    )
                    self.stackedMessages.append(tuple)
                }
                self.layoutTargetsAndStartAnimation()
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

        // 立刻 layout 在底部
        layoutBottomMessage()
    }




    let minVisibleCount = 2

    // MARK: - Layout + Animation 修正版（可直接替換）
    private func layoutTargetsAndStartAnimation() {
        visible.removeAll()


        var yCursor = topMargin

        // 重新排 targetY，同時決定 visible
        for msg in stackedMessages {

            // 未 fade 的訊息
            msg.targetY = yCursor

            visible.append(msg)


            yCursor += msg.height + msg.verticalSpacing

            // 新訊息從底部進入動畫
            if msg.isNew && !animatingMessages.contains(msg) {
                let bottomY = bottomMessage?.avatar.frame.origin.y ?? container.bounds.height
                msg.startY = bottomY - msg.height - msg.verticalSpacing
                animatingMessages.append(msg)
            }
        }

        // 重新 layout 底部固定訊息
        layoutBottomMessage()

        // 啟動 displayLink
        if displayLink == nil {
            displayLink = CADisplayLink(target: self, selector: #selector(stepAnimationDisplayLink))
            displayLink?.add(to: .main, forMode: .common)
            isAnimating = true
        }

        // Debug 輸出
        print("--- layoutTargets ---")
        for (i, msg) in stackedMessages.enumerated() {
            print(
                "stacked[\(i)]  [\(String(describing: msg.message.string))] alpha:\(msg.alpha) startY:\(msg.startY) targetY:\(msg.targetY) isNew:\(msg.isNew)"
            )
        }
        if let bottom = bottomMessage {
            print("bottomMessage startY:\(bottom.avatar.frame.origin.y)")
        }
    }

    // MARK: - 每幀動畫
    @objc private func stepAnimationDisplayLink() {
//        let maxVisibleY = container.bounds.height - (bottomMessage?.height ?? 0) - 8

        // 動畫每幀滑動
        let snapThreshold: CGFloat = 0.5

        let activeAnimating = animatingMessages.prefix(8)
        for msg in activeAnimating {
            let distance = msg.targetY - msg.startY

            if abs(distance) < snapThreshold {
                msg.startY = msg.targetY
                layout(msg: msg, y: msg.startY)
            } else {
                msg.startY += distance * 0.2
                layout(msg: msg, y: msg.startY)
            }
        }

        //  清理已經到位動畫
        animatingMessages.removeAll {
            abs($0.startY - $0.targetY) < snapThreshold
        }


        // 舊訊息向 targetY 移動
        for msg in visible {
            let distance = msg.targetY - msg.startY
            msg.startY += distance * 0.2
            layout(msg: msg, y: msg.startY)
        }

        // Fade 超出底部訊息
        // 只處理最上面的訊息
        guard let topMsg = stackedMessages.min(by: { $0.startY < $1.startY }) else { return }

        let fadeThreshold: CGFloat = 1.0

        let canFade = stackedMessages.count > minVisibleCount

        if canFade && topMsg.startY <= topMargin + fadeThreshold {
            topMsg.alpha -= 0.04
            if topMsg.alpha < 0.01 {
                topMsg.alpha = 0
            }

            topMsg.avatar.opacity = Float(topMsg.alpha)
            topMsg.name.opacity = Float(topMsg.alpha)
            topMsg.message.opacity = Float(topMsg.alpha)
            topMsg.gift?.opacity = Float(topMsg.alpha)
        }


        // ✅ 新增：重新排剩下的訊息 targetY
        var yCursor = topMargin

        for msg in stackedMessages where msg.alpha > 0 {
            msg.targetY = yCursor
            yCursor += msg.height + msg.verticalSpacing
        }


        // 刪除完全透明訊息
        stackedMessages.removeAll { msg in
            guard msg.alpha <= 0 else { return false }

            msg.avatar.removeFromSuperlayer()
            msg.name.removeFromSuperlayer()
            msg.message.removeFromSuperlayer()
            msg.gift?.removeFromSuperlayer()
            animatingMessages.removeAll { $0 === msg }
            return true
        }



        // 動畫完成判斷
        let hasAnimatingMessages = !animatingMessages.isEmpty

        let hasMovingMessages = visible.contains {
            abs($0.startY - $0.targetY) >= 0.5
        }



        let hasFadingMessages = stackedMessages.contains { msg in
            let isFading = msg.alpha > 0 && msg.alpha < 1.0
            if isFading {
                logTo("🟡 fading alpha = \(msg.alpha)")
            }
            return isFading
        }


        logTo("hasA:\(hasAnimatingMessages) hasFM:\(hasMovingMessages) hasF:\(hasFadingMessages)")




        if !hasAnimatingMessages && !hasMovingMessages && !hasFadingMessages {
            displayLink?.invalidate()
            displayLink = nil

            animatingMessages.forEach { $0.isNew = false }
            animatingMessages.removeAll()
            isAnimating = false

            Task  { @MainActor in
                PIPService.shared.isAnimatingMessages = false
                PIPService.shared.startDecayAfterAnimation()
            }
        }

        // Debug: 每幀輸出 animatingMessages 狀態
        print("--- stepAnimation ---")
        for (i, msg) in animatingMessages.enumerated() {
            print(
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
        let font = msg.font ?? self.font
        let avatarSizeLocal = msg.avatarSize ?? self.avatarSize
        let giftSizeLocal = msg.giftSize ?? self.giftSize

        msg.avatar.frame.origin.y = y

        // Name
        let maxNameWidth = container.bounds.width - leftPadding*2 - avatarSizeLocal - horizontalSpacing
        let userName = (msg.name.string as? String) ?? ""
        let nameSize = (userName as NSString).boundingRect(
            with: CGSize(width: maxNameWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).size
        msg.name.frame = CGRect(
            x: leftPadding + avatarSizeLocal + horizontalSpacing,
            y: y,
            width: maxNameWidth,
            height: nameSize.height
        )

        // Message
        let maxMessageWidth = container.bounds.width - leftPadding*2 - avatarSizeLocal - horizontalSpacing - (msg.gift != nil ? giftSizeLocal + 2 : 0)
        let messageText = (msg.message.string as? String) ?? ""
        let messageSize = (messageText as NSString).boundingRect(
            with: CGSize(width: maxMessageWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).size

        let messageY = msg.name.frame.maxY + msg.verticalSpacing

        msg.message.frame = CGRect(
            x: leftPadding + avatarSizeLocal + horizontalSpacing,
            y: messageY,
            width: maxMessageWidth,
            height: messageSize.height
        )

        // Gift
        if let gift = msg.gift {
            let lastLineWidth = (messageText as NSString).boundingRect(
                with: CGSize(width: maxMessageWidth, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            ).size.width

            gift.frame = CGRect(
                x: msg.message.frame.origin.x + lastLineWidth + 2,
                y: msg.message.frame.midY - giftSizeLocal / 2,
                width: giftSizeLocal,
                height: giftSizeLocal
            )
        }

        // 訊息高度
        let spacing = msg.verticalSpacing
        let textBlockHeight = nameSize.height + spacing + messageSize.height
        msg.height = max(avatarSizeLocal, textBlockHeight) + spacing


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

    var body: some View {

        VStack(spacing: 20) {
            Text("Chat")


            Button("TestB"){
                // 新訊息
                let imgA = "https://img.icons8.com/?size=100&id=12860&format=png&color=000000"

                let imgG = "https://img.icons8.com/?size=100&id=y5xu7jml0MTU&format=png&color=000000"


                PIPService.shared.addMessage(
                    user: "小明2",
                    msg: "Hello!",
                    imgURL: imgA,
                    giftURL: imgG
                )
            }
            Button("Test次要訊息"){
                // 新訊息
                let imgA = "https://img.icons8.com/?size=100&id=12860&format=png&color=000000"

                let imgG = "https://img.icons8.com/?size=100&id=y5xu7jml0MTU&format=png&color=000000"


                PIPService.shared.addMessage(
                    user: "小明2",
                    msg: "Hello!",
                    imgURL: imgA,
                    giftURL: imgG,
                    isMain: false
                )
            }

            Button("新增訊息") {
                PIPService.shared
                    .addMessage(
                        msg:"測試訊息圖片",imgURL: "https://img.icons8.com/?size=100&id=12860&format=png&color=000000",giftURL: "https://img.icons8.com/?size=100&id=y5xu7jml0MTU&format=png&color=000000"
                    )
            }

            Button("[測試組]啟動 PiP") {

                // 設定 PiP 顯示尺寸


                // 啟動測試 PiP
                PIPTestService.shared.startPiPTest(size: CGSize(width: 300, height: 200))


            }
            
            Button("[測試組]停止 PiP") {
                PIPTestService.shared.stopPiP()

            }
            Button("[聊天組]啟動 PiP"){
                let pipSize = CGSize(width: 300, height: 200)


                // 啟動 PiP
                PIPService.shared
                    .startPiP(
                        size: pipSize

                    )

            }
            Button("[聊天室]停止PIP") {
                PIPService.shared.stopPiP()
            }

            // 將 debugImageView 顯示在 SwiftUI
            DebugImageViewWrapper()
                .frame(width: 150, height: 100)
                .border(Color.red)
        }
    }
}

// 這是一個你自訂的內容（聊天室/動畫等）
