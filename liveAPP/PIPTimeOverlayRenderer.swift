import UIKit

/// 時間疊加的共用繪製；PiP 實際畫面與排版預覽都走這一份，避免座標與字級分岔。
enum PIPTimeOverlayRenderer {
    /// 一幀時間疊加所需的內容；由呼叫端從即時狀態或預覽假資料組出。
    struct Scene {
        let elapsedString: String
        let nowTimeText: String
        let nowTimeLabel: String
        let statusText: String
        let statusEnded: Bool
        let viewerCount: Int?
        let isReconnecting: Bool
        let reconnectText: String
        let secondaryNotice: String?
    }

    private static let clockIcon = UIImage(systemName: "clock.fill")?.withTintColor(
        #colorLiteral(red: 1.0, green: 0.6, blue: 0.6, alpha: 1.0),
        renderingMode: .alwaysOriginal
    )
    private static let viewerIcon = UIImage(systemName: "person.2.fill")
    private static let reconnectIcon = UIImage(systemName: "antenna.radiowaves.left.and.right")

    static func draw(in cg: CGContext, size: CGSize, scene: Scene) {
        cg.saveGState()
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1.0, y: -1.0)

        let elapsedFont = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        let elapsedLabelFont = UIFont.systemFont(ofSize: 14, weight: .medium)


        let fontSize: CGFloat = 16
        let timeFont = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let labelFont = UIFont.systemFont(ofSize: fontSize, weight: .medium)

        let fullLine = NSMutableAttributedString()
        let nowLabel = scene.nowTimeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        fullLine.append(NSAttributedString(string: "\(nowLabel.isEmpty ? "現在時間" : nowLabel) ", attributes: [.font: labelFont, .foregroundColor: UIColor.systemCyan]))
        fullLine.append(NSAttributedString(string: scene.nowTimeText, attributes: [.font: timeFont, .foregroundColor: UIColor.white]))

        let textSize = fullLine.size()
        let paddingX: CGFloat = 6
        let paddingY: CGFloat = 4

        let bgRect = CGRect(
            x: PIPOverlayLayout.contentLeading - paddingX,
            y: PIPOverlayLayout.nowTimeY - paddingY,
            width: textSize.width + paddingX * 2,
            height: textSize.height + paddingY * 2
        )

        let textPoint = CGPoint(x: bgRect.minX + paddingX, y: bgRect.maxY - paddingY - textSize.height)

        UIGraphicsPushContext(cg)

        // 計時獨立置中於兩側控制鈕之間，不把整片內容推到控制帶下方。
        let timerWidth = max(1, size.width - PIPOverlayLayout.controlSideInset * 2)
        let timerStyle = NSMutableParagraphStyle()
        timerStyle.alignment = .center
        timerStyle.lineBreakMode = .byTruncatingTail
        (scene.elapsedString as NSString).draw(in: CGRect(x: PIPOverlayLayout.controlSideInset,
            y: PIPOverlayLayout.timerY, width: timerWidth, height: 20),
            withAttributes: [.font: elapsedFont, .foregroundColor: UIColor.white, .paragraphStyle: timerStyle])

        // 狀態與人數使用自己的第二列；重連狀態取代普通狀態，不新增遮住聊天室的行。
        let status = scene.isReconnecting ? scene.reconnectText : scene.statusText
        let viewers = scene.viewerCount.map { $0 >= 10000 ? String(format: "%.1f萬", Double($0) / 10000) : String($0) }
        let viewerWidth = viewers.map { badgeWidth(text: $0, font: elapsedLabelFont, icon: viewerIcon) } ?? 0
        let available = max(1, size.width - PIPOverlayLayout.contentLeading - PIPOverlayLayout.contentTrailing)
        let statusLimit = max(1, available - viewerWidth - 8)
        var shortStatus = status
        while !shortStatus.isEmpty && badgeWidth(text: shortStatus + "…", font: elapsedLabelFont, icon: nil) > statusLimit {
            shortStatus.removeLast()
        }
        if shortStatus != status { shortStatus += "…" }
        var badgeX = PIPOverlayLayout.contentLeading
        if !status.isEmpty {
            badgeX += drawBadge(in: cg, text: shortStatus, font: elapsedLabelFont,
                origin: CGPoint(x: badgeX, y: PIPOverlayLayout.statusRowY), textColor: .white,
                bgColor: scene.statusEnded ? .darkGray : .systemOrange) + 6
        }
        if let viewers, badgeX + viewerWidth <= size.width - PIPOverlayLayout.contentTrailing {
            _ = drawBadge(in: cg, text: viewers, font: elapsedLabelFont,
                origin: CGPoint(x: badgeX, y: PIPOverlayLayout.statusRowY), textColor: .darkGray,
                bgColor: .lightGray, icon: viewerIcon)
        }

        // 長日期或自訂標籤限制在內容寬度內，不讓尾端超出視窗。
        let timeParagraph = NSMutableParagraphStyle()
        timeParagraph.lineBreakMode = .byTruncatingTail
        fullLine.addAttribute(.paragraphStyle, value: timeParagraph, range: NSRange(location: 0, length: fullLine.length))
        fullLine.draw(in: CGRect(origin: textPoint, size: CGSize(width: available, height: 20)))

        if let notice = scene.secondaryNotice {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let noticeY = PIPOverlayLayout.noticeY
            (notice as NSString).draw(in: CGRect(
                x: PIPOverlayLayout.contentLeading,
                y: noticeY,
                width: max(1, size.width - PIPOverlayLayout.contentLeading - PIPOverlayLayout.contentTrailing),
                height: 18),
                withAttributes: [.font: UIFont.systemFont(ofSize: 12),
                                 .foregroundColor: UIColor.lightGray, .paragraphStyle: paragraph])
        }

        UIGraphicsPopContext()
        cg.restoreGState()
    }

    /// 與 `drawBadge` 使用相同的寬度公式，供排版先行取捨。
    private static func badgeWidth(text: String, font: UIFont, icon: UIImage?) -> CGFloat {
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let iconSize = icon == nil ? 0 : max(font.lineHeight - 2, 10)
        let iconSpacing: CGFloat = icon == nil ? 0 : 4
        return ceil(textSize.width + 8 + 8 + iconSize + iconSpacing)
    }

    private static func drawBadge(
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
}
