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

        let imageHeight: CGFloat = elapsedLabelFont.lineHeight
        let imageWidth: CGFloat = imageHeight
        let elapsedPoint = CGPoint(x: PIPOverlayLayout.contentLeading, y: PIPOverlayLayout.statusRowY)

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

        let elapsedTextSize = (scene.elapsedString as NSString).size(withAttributes: [.font: elapsedFont])
        let statusWidth = scene.statusText.isEmpty ? 0 : badgeWidth(text: scene.statusText, font: elapsedLabelFont, icon: nil)
        let viewerWidth = scene.viewerCount.map { badgeWidth(text: "\($0)", font: elapsedLabelFont, icon: viewerIcon) } ?? 0
        let plan = PIPOverlayLayout.statusRowPlan(
            availableWidth: PIPOverlayLayout.statusRowAvailableWidth(canvasWidth: size.width),
            iconWidth: imageWidth,
            elapsedWidth: elapsedTextSize.width,
            statusWidth: statusWidth,
            viewerWidth: viewerWidth
        )

        if plan.drawIcon {
            clockIcon?.draw(in: CGRect(
                x: elapsedPoint.x,
                y: elapsedPoint.y + (elapsedFont.capHeight - imageHeight) * 0.5,
                width: imageWidth,
                height: imageHeight
            ))
        }

        let timeTextPoint = CGPoint(
            x: elapsedPoint.x + (plan.drawIcon ? imageWidth + 4 : 0),
            y: elapsedPoint.y + (elapsedFont.capHeight - elapsedFont.lineHeight) * 0.5
        )

        (scene.elapsedString as NSString).draw(at: timeTextPoint, withAttributes: [.font: elapsedFont, .foregroundColor: UIColor.white])

        var badgeX = timeTextPoint.x + elapsedTextSize.width + 8
        let badgeY = timeTextPoint.y + (elapsedFont.capHeight - elapsedLabelFont.lineHeight) * 0.5

        if !scene.statusText.isEmpty {
            var endColor = #colorLiteral(red: 1, green: 0.4538183808, blue: 0.1835401952, alpha: 1)
            if scene.statusEnded { endColor = #colorLiteral(red: 0.2549019754, green: 0.2745098174, blue: 0.3019607961, alpha: 1) }

            let drawnStatusWidth = drawBadge(in: cg, text: scene.statusText, font: elapsedLabelFont,
                                             origin: CGPoint(x: badgeX, y: badgeY),
                                             textColor: .white, bgColor: endColor,
                                             padding: UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8))
            badgeX += drawnStatusWidth + 6
        }

        if plan.drawViewer, let viewerCount = scene.viewerCount {
            _ = drawBadge(in: cg, text: "\(viewerCount)", font: elapsedLabelFont,
                          origin: CGPoint(x: badgeX, y: badgeY),
                          textColor: UIColor(white: 0.16, alpha: 1.0),
                          bgColor: UIColor(white: 0.83, alpha: 1.0),
                          icon: viewerIcon,
                          iconTintColor: UIColor(white: 0.22, alpha: 1.0),
                          padding: UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8))
        }

        fullLine.draw(at: textPoint)

        if scene.isReconnecting {
            badgeX = timeTextPoint.x + elapsedTextSize.width + 8
            _ = drawBadge(in: cg, text: scene.reconnectText, font: elapsedLabelFont,
                          origin: CGPoint(x: badgeX, y: PIPOverlayLayout.noticeY),
                          textColor: .white,
                          bgColor: #colorLiteral(red: 1, green: 0.6, blue: 0, alpha: 1),
                          icon: reconnectIcon, iconTintColor: .white,
                          padding: UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8))
        }

        if let notice = scene.secondaryNotice {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let noticeY = PIPOverlayLayout.noticeY
                + (scene.isReconnecting ? PIPOverlayLayout.noticeLineHeight : 0)
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
