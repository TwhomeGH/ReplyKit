with open(r'C:\Users\agp05\OneDrive\桌面\ReplyKit\liveAPP\PIPS.tmp', 'r', encoding='utf-8') as f:
    c = f.read()

old = '''        if isKeepaliveMode {
            let timeFont = UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .regular)
            let labelFont = UIFont.boldSystemFont(ofSize: 18)
            let timeSize = (timeText as NSString).size(withAttributes: [.font: timeFont])
            let labelSize = ("保活用子母工作中" as NSString).size(withAttributes: [.font: labelFont])
            let maxW = max(timeSize.width, labelSize.width) + 24
            let totalH = timeSize.height + labelSize.height + 16
            let x = (size.width - maxW) / 2
            let y = (size.height - totalH) / 2

            cg.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
            cg.fill(CGRect(x: x, y: y, width: maxW, height: totalH))

            (timeText as NSString).draw(
                at: CGPoint(x: x + (maxW - timeSize.width) / 2, y: y + 6),
                withAttributes: [.font: timeFont, .foregroundColor: UIColor.white]
            )
            ("保活用子母工作中" as NSString).draw(
                at: CGPoint(x: x + (maxW - labelSize.width) / 2, y: y + 6 + timeSize.height + 4),
                withAttributes: [.font: labelFont, .foregroundColor: UIColor.systemGreen]
            )
            return
        }'''

new = '''        if isKeepaliveMode {
            let timeFont = UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .regular)
            let labelFont = UIFont.boldSystemFont(ofSize: 18)
            let timeSize = (timeText as NSString).size(withAttributes: [.font: timeFont])
            let labelSize = ("保活用子母工作中" as NSString).size(withAttributes: [.font: labelFont])
            let maxW = max(timeSize.width, labelSize.width) + 24
            let totalH = timeSize.height + labelSize.height + 16
            let x = (size.width - maxW) / 2
            let y = (size.height - totalH) / 2

            cg.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
            cg.fill(CGRect(x: x, y: y, width: maxW, height: totalH))

            UIGraphicsPushContext(cg)
            (timeText as NSString).draw(
                at: CGPoint(x: x + (maxW - timeSize.width) / 2, y: y + 6),
                withAttributes: [.font: timeFont, .foregroundColor: UIColor.white]
            )
            ("保活用子母工作中" as NSString).draw(
                at: CGPoint(x: x + (maxW - labelSize.width) / 2, y: y + 6 + timeSize.height + 4),
                withAttributes: [.font: labelFont, .foregroundColor: UIColor.systemGreen]
            )
            UIGraphicsPopContext()
            return
        }'''

if old in c:
    c = c.replace(old, new, 1)
    with open(r'C:\Users\agp05\OneDrive\桌面\ReplyKit\liveAPP\PIPS.tmp', 'w', encoding='utf-8') as f:
        f.write(c)
    print('OK')
else:
    print('NOT FOUND')
