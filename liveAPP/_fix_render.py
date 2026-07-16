with open(r'C:\Users\agp05\OneDrive\桌面\ReplyKit\liveAPP\PIPService.swift', 'r', encoding='utf-8') as f:
    c = f.read()

old = '        messagesLayer?.container.render(in: context)\n        context.restoreGState()'
new = '        if !isKeepaliveMode {\n            messagesLayer?.container.render(in: context)\n        }\n        context.restoreGState()'

if old in c:
    c = c.replace(old, new, 1)
    with open(r'C:\Users\agp05\OneDrive\桌面\ReplyKit\liveAPP\PIPService.swift', 'w', encoding='utf-8') as f:
        f.write(c)
    print('OK')
else:
    print('NOT FOUND')
