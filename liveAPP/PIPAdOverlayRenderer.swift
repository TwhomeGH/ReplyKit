import UIKit

/// 贊助覆蓋的共用繪製；runtime 與排版預覽使用同一份版面。
enum PIPAdOverlayRenderer {
    struct Scene {
        let user: String
        let text: String
        let range: NSRange
        let emojiPositionMap: [Int: Int]
        let emojiImages: [UIImage?]
        let icon: UIImage?
        let alpha: CGFloat
        let userFontSize: CGFloat
        let textFontSize: CGFloat
        let spacing: CGFloat
        let pageIndex: Int
        let pageCount: Int
        let logSkipCounter: Int
    }

    static func draw(in cg: CGContext, size: CGSize, scene: Scene) {
        cg.saveGState()
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1.0, y: -1.0)
        cg.setAlpha(scene.alpha)

        let bannerW = size.width * 0.88
        let bannerX = (size.width - bannerW) / 2
        let bannerY: CGFloat = 85

        let labelFont = UIFont.boldSystemFont(ofSize: max(1, scene.userFontSize))
        let overlayFontSize = max(1, scene.textFontSize)
        let textFont = UIFont.systemFont(ofSize: overlayFontSize)
        let overlaySpacing = max(0, scene.spacing)
        let bannerH: CGFloat = max(52, 6 + labelFont.lineHeight + overlaySpacing + textFont.lineHeight * 2 + 4 + 4)

        let bgRect = CGRect(x: bannerX, y: bannerY, width: bannerW, height: bannerH)
        let path = UIBezierPath(roundedRect: bgRect, cornerRadius: 10)
        cg.setFillColor(UIColor(red: 0.9, green: 0.55, blue: 0.05, alpha: 0.88).cgColor)
        path.fill()

        UIGraphicsPushContext(cg)

        let iconSize: CGFloat = 28
        let iconX = bannerX + 8

        let textX = iconX + iconSize + 8
        let textW = bannerW - (textX - bannerX) - 8

        let msgY = bannerY + 6 + labelFont.lineHeight + overlaySpacing
        let msgH = bannerY + bannerH - 4 - msgY

        let msgRect = CGRect(x: textX, y: msgY, width: textW, height: msgH)

        // 先建立 CTFrame 算出實際渲染色高度，再決定 icon 位置
        let attrStr = NSAttributedString(string: scene.text, attributes: [.font: textFont, .foregroundColor: UIColor(white: 1, alpha: 0.9)])
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let cgPathRect = CGRect(origin: .zero, size: msgRect.size)
        let cgPath = CGPath(rect: cgPathRect, transform: nil)
        let ctFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attrStr.length), cgPath, nil)
        let lines = CTFrameGetLines(ctFrame) as! [CTLine]
        var lineOrigins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(ctFrame, CFRange(location: 0, length: lines.count), &lineOrigins)

        // 計算實際文字底部（最後一行 baseline + lineHeight）
        let lastLineY: CGFloat
        if let lastOrigin = lineOrigins.last {
            lastLineY = msgRect.origin.y + msgRect.height - lastOrigin.y
        } else {
            lastLineY = msgY + textFont.lineHeight
        }

        // icon 垂直置中於名稱區塊與文字區塊各自的視覺中心平均值
        let nameCenterY = bannerY + 6 + labelFont.lineHeight / 2
        let textCenterY = msgY + (lastLineY - msgY) / 2
        let iconCenterY = (nameCenterY + textCenterY) / 2
        let iconY = iconCenterY - iconSize / 2
        let iconRect = CGRect(x: iconX, y: iconY, width: iconSize, height: iconSize)

        if let icon = scene.icon {
            cg.saveGState()
            cg.addEllipse(in: iconRect)
            cg.clip()
            icon.draw(in: iconRect)
            cg.restoreGState()
        } else {
            UIImage(systemName: "star.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: iconRect)
        }

        (scene.user as NSString).draw(at: CGPoint(x: textX, y: bannerY + 6), withAttributes: [
            .font: labelFont,
            .foregroundColor: UIColor.white
        ])

        let logs = scene.logSkipCounter.isMultiple(of: 30)
        if logs {
            PIPLogTo("AdOverlay: drawing page=\(scene.pageIndex)/\(scene.pageCount) range=\(scene.range) text='\(scene.text)' positions=\(scene.emojiPositionMap.keys.sorted()) emojiLoaded=\(scene.emojiImages.compactMap({ $0 != nil }).count)/\(scene.emojiImages.count)")
        }

        for (li, line) in lines.enumerated() {
            let lineOrigin = lineOrigins[li]
            let lineY = msgRect.origin.y + msgRect.height - lineOrigin.y - textFont.lineHeight
            let lineRange = CTLineGetStringRange(line)
            let lineStart = lineRange.location
            let lineEnd = lineRange.location + lineRange.length
            let nsText = scene.text as NSString

            if li == 0, logs {
                PIPLogTo("AdOverlay: msgRect=\(msgRect) lineOrigin=\(lineOrigin) lineHeight=\(textFont.lineHeight) lineY=\(lineY)")
            }

            var charIdx = lineStart
            while charIdx < lineEnd {
                let globalPos = scene.range.location + charIdx
                let foundEmojiPos = scene.emojiPositionMap[globalPos]

                if logs {
                    PIPLogTo("AdOverlay: charIdx=\(charIdx) globalPos=\(globalPos) posMatch=\(foundEmojiPos ?? -1) imgCount=\(scene.emojiImages.count) imgLoaded=\(foundEmojiPos.map { $0 < scene.emojiImages.count && scene.emojiImages[$0] != nil } ?? false)")
                }

                if let emojiIdx = foundEmojiPos,
                   emojiIdx < scene.emojiImages.count,
                   let img = scene.emojiImages[emojiIdx] {
                    let emojiX = msgRect.origin.x + CTLineGetOffsetForStringIndex(line, charIdx, nil)
                    let emojiSize: CGFloat = overlayFontSize * 1.2
                    let emojiY = lineY + (textFont.lineHeight - emojiSize) / 2
                    img.draw(in: CGRect(x: emojiX, y: emojiY, width: emojiSize, height: emojiSize))
                    if logs { PIPLogTo("AdOverlay: emoji[\(emojiIdx)] at line=\(li) x=\(emojiX) y=\(emojiY)") }
                    charIdx += 1
                } else {
                    var segEnd = charIdx + 1
                    while segEnd < lineEnd {
                        let nextGlobalPos = scene.range.location + segEnd
                        if scene.emojiPositionMap[nextGlobalPos] != nil { break }
                        segEnd += 1
                    }
                    let segRange = NSRange(location: charIdx, length: segEnd - charIdx)
                    let segStr = nsText.substring(with: segRange)
                    let textX = msgRect.origin.x + CTLineGetOffsetForStringIndex(line, charIdx, nil)
                    (segStr as NSString).draw(at: CGPoint(x: textX, y: lineY), withAttributes: [
                        .font: textFont,
                        .foregroundColor: UIColor(white: 1, alpha: 0.9)
                    ])
                    charIdx = segEnd
                }
            }
        }

        UIGraphicsPopContext()
        cg.restoreGState()
    }
}
