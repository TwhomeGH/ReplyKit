with open('C:\\Users\\agp05\\OneDrive\\桌面\\ReplyKit\\liveAPP\\PIPService.swift.tmp', 'r', encoding='utf-8') as f:
    content = f.read()

# 1. StopPiP: reset isKeepaliveMode
content = content.replace(
    '        cancelRenderTimer()\n\n        self.pipController?.stopPictureInPicture()',
    '        cancelRenderTimer()\n        isKeepaliveMode = false\n\n        self.pipController?.stopPictureInPicture()',
    1
)

# 2. decayFPSIfNeeded: check keepalive mode first
old_decay = '''    func decayFPSIfNeeded() {
        let now = CACurrentMediaTime()

        guard let messagesLayer = messagesLayer else {
            if currentFPS != idleFPS {
                currentFPS = idleFPS
            }
            return
        }'''

new_decay = '''    func decayFPSIfNeeded() {
        guard !isKeepaliveMode else {
            if abs(currentFPS - keepaliveFPS) > 0.01 {
                currentFPS = keepaliveFPS
            }
            return
        }

        let now = CACurrentMediaTime()

        guard let messagesLayer = messagesLayer else {
            if currentFPS != idleFPS {
                currentFPS = idleFPS
            }
            return
        }'''

content = content.replace(old_decay, new_decay, 1)

# 3. renderUIViewToPixelBuffer: skip messagesLayer in keepalive mode
old_render = '''        guard let context = CGContext(
            data: baseAddress,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,'''

new_render = '''        if !isKeepaliveMode {
            messagesLayer?.container.render(in: context)
        }

        guard let context = CGContext(
            data: baseAddress,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,'''

content = content.replace(old_render, new_render, 1)

# 4. drawTimeOverlay: show keepalive text
old_time = '''        let timeText = currentTimeString()'''

new_time = '''        let timeText = currentTimeString()
        if isKeepaliveMode {
            let kaText = "保活用子母工作中 \\(timeText)"
            let kaFont = UIFont.boldSystemFont(ofSize: 18)
            let kaSize = (kaText as NSString).size(withAttributes: [.font: kaFont])
            let kaRect = CGRect(
                x: (size.width - kaSize.width) / 2 - 8,
                y: (size.height - kaSize.height) / 2 - 4,
                width: kaSize.width + 16,
                height: kaSize.height + 8
            )
            cg.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
            cg.fill(kaRect)
            (kaText as NSString).draw(
                at: CGPoint(x: kaRect.minX + 8, y: kaRect.minY + 4),
                withAttributes: [.font: kaFont, .foregroundColor: UIColor.systemGreen]
            )
            return
        }'''

content = content.replace(old_time, new_time, 1)

with open('C:\\Users\\agp05\\OneDrive\\桌面\\ReplyKit\\liveAPP\\PIPService.swift.tmp', 'w', encoding='utf-8') as f:
    f.write(content)
print('OK')
