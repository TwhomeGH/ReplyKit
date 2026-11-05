import UIKit

/// 排版預覽的整幀輸出；聊天、時間與贊助都走正式繪製路徑，SwiftUI 只負責縮放顯示。
enum PIPPreviewFrameRenderer {
    struct Scene {
        let time: PIPTimeOverlayRenderer.Scene
        let ad: PIPAdOverlayRenderer.Scene?
        let chatMain: (user: String, message: String, fontSize: CGFloat, avatar: UIImage?)?
        let chatSecondary: (user: String, message: String, fontSize: CGFloat, avatar: UIImage?)?
    }

    static func render(size: CGSize = CGSize(width: 300, height: 200), scene: Scene) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            // 正式 renderer 接受左下原點；UIKit 預覽先轉一次，避免各圖層二次翻轉。
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            cg.setFillColor(UIColor.black.cgColor)
            cg.fill(CGRect(origin: .zero, size: size))

            if scene.chatMain != nil || scene.chatSecondary != nil {
                let messages = PIPServiceMessages(size: size, scrollSpeed: LPConfig.shared.ScrollTime)
                if let main = scene.chatMain {
                    messages.snapshotMessage(user: main.user, message: main.message,
                                             isMain: true, fontSize: main.fontSize,
                                             avatarImage: main.avatar)
                }
                if let secondary = scene.chatSecondary {
                    messages.snapshotMessage(user: secondary.user, message: secondary.message,
                                             isMain: false, fontSize: secondary.fontSize,
                                             avatarImage: secondary.avatar)
                }
                cg.saveGState()
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1.0, y: -1.0)
                messages.container.render(in: cg)
                cg.restoreGState()
            }

            PIPTimeOverlayRenderer.draw(in: cg, size: size, scene: scene.time)

            if let ad = scene.ad {
                PIPAdOverlayRenderer.draw(in: cg, size: size, scene: ad)
            }
        }
    }
}
