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
        var secondaryNoticeAvatar: UIImage? = nil
        var secondaryNoticePageIndex: Int = 0
        var secondaryNoticePageCount: Int = 0
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

        let controlsVisible = !PIPSystemControls.hidesAll
        let rowLeading = controlsVisible
            ? PIPOverlayLayout.controlSideInset
            : PIPOverlayLayout.contentLeading
        let rowTrailing = controlsVisible
            ? PIPOverlayLayout.controlSideInset
            : PIPOverlayLayout.contentTrailing
        let rowRight = size.width - rowTrailing
        let rowY = PIPOverlayLayout.statusRowY

        // 計時器併入直播狀態列：與徽章同高、靠左，不再單獨置中。
        let elapsedSize = (scene.elapsedString as NSString).size(withAttributes: [.font: elapsedFont])
        (scene.elapsedString as NSString).draw(at: CGPoint(x: rowLeading, y: rowY + 2),
            withAttributes: [.font: elapsedFont, .foregroundColor: UIColor.white])
        var badgeX = rowLeading + elapsedSize.width + 8

        // 重連狀態取代普通狀態，不新增遮住聊天室的行。
        let status = scene.isReconnecting ? scene.reconnectText : scene.statusText
        let viewers = scene.viewerCount.map { $0 >= 10000 ? String(format: "%.1f萬", Double($0) / 10000) : String($0) }
        let viewerWidth = viewers.map { badgeWidth(text: $0, font: elapsedLabelFont, icon: viewerIcon) } ?? 0
        let viewerGap: CGFloat = viewers == nil ? 0 : 8
        let statusLimit = max(0, rowRight - badgeX - viewerWidth - viewerGap)
        var shortStatus = status
        while !shortStatus.isEmpty && badgeWidth(text: shortStatus + "…", font: elapsedLabelFont, icon: nil) > statusLimit {
            shortStatus.removeLast()
        }
        if shortStatus != status { shortStatus += "…" }
        if !shortStatus.isEmpty {
            badgeX += drawBadge(in: cg, text: shortStatus, font: elapsedLabelFont,
                origin: CGPoint(x: badgeX, y: rowY), textColor: .white,
                bgColor: scene.statusEnded ? .darkGray : .systemOrange) + 6
        }
        if let viewers, badgeX + viewerWidth <= rowRight {
            _ = drawBadge(in: cg, text: viewers, font: elapsedLabelFont,
                origin: CGPoint(x: badgeX, y: rowY), textColor: .darkGray,
                bgColor: .lightGray, icon: viewerIcon)
        }
        let available = max(1, size.width - PIPOverlayLayout.contentLeading - PIPOverlayLayout.contentTrailing)

        // 長日期或自訂標籤限制在內容寬度內，不讓尾端超出視窗。
        let timeParagraph = NSMutableParagraphStyle()
        timeParagraph.lineBreakMode = .byTruncatingTail
        fullLine.addAttribute(.paragraphStyle, value: timeParagraph, range: NSRange(location: 0, length: fullLine.length))
        fullLine.draw(in: CGRect(origin: textPoint, size: CGSize(width: available, height: 20)))

        if let notice = scene.secondaryNotice {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let noticeY = PIPOverlayLayout.noticeY
            var textX = PIPOverlayLayout.contentLeading

            if let avatar = scene.secondaryNoticeAvatar {
                let avatarSize = PIPOverlayLayout.noticeAvatarSize
                let avatarRect = CGRect(x: textX, y: noticeY + 1,
                                        width: avatarSize, height: avatarSize)
                cg.saveGState()
                cg.addEllipse(in: avatarRect)
                cg.clip()
                avatar.draw(in: avatarRect)
                cg.restoreGState()
                textX += avatarSize + PIPOverlayLayout.noticeAvatarGap
            }

            let pageCount = scene.secondaryNoticePageCount
            let dotsWidth = pageCount > 1
                ? CGFloat(pageCount) * (PIPOverlayLayout.noticePageDotSize + PIPOverlayLayout.noticePageDotGap)
                : 0
            let rightReserve = PIPOverlayLayout.contentTrailing + (dotsWidth > 0 ? dotsWidth + 6 : 0)
            (notice as NSString).draw(in: CGRect(
                x: textX, y: noticeY,
                width: max(1, size.width - textX - rightReserve), height: 18),
                withAttributes: [.font: UIFont.systemFont(ofSize: 12),
                                 .foregroundColor: UIColor.lightGray, .paragraphStyle: paragraph])

            if pageCount > 1 {
                let dotSize = PIPOverlayLayout.noticePageDotSize
                let dotGap = PIPOverlayLayout.noticePageDotGap
                var dotX = size.width - PIPOverlayLayout.contentTrailing - dotsWidth
                let dotY = noticeY + 7
                for index in 0..<pageCount {
                    cg.setFillColor((index == scene.secondaryNoticePageIndex
                        ? UIColor.white : UIColor(white: 1, alpha: 0.3)).cgColor)
                    cg.fillEllipse(in: CGRect(x: dotX, y: dotY, width: dotSize, height: dotSize))
                    dotX += dotSize + dotGap
                }
            }
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
