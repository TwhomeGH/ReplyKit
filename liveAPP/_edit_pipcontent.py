with open('C:\\Users\\agp05\\OneDrive\\桌面\\ReplyKit\\liveAPP\\PIPContent.swift.tmp', 'r', encoding='utf-8') as f:
    content = f.read()

old = '                VStack(spacing: 10) {\n                    Button("[聊天組]啟動 PiP") {\n                        let pipSize = CGSize(width: 300, height: 200)\n                        PIPService.shared.startPiP(size: pipSize)\n                    }\n                    .disabled(pipService.isPiPActive || isTestPiPActive)\n\n                    Button("[聊天室]停止 PiP") {\n                        PIPService.shared.stopPiP()\n                    }\n                    .disabled(!pipService.isPiPActive)\n                }'

new = '                VStack(spacing: 10) {\n                    Button("[聊天組]啟動 PiP") {\n                        let pipSize = CGSize(width: 300, height: 200)\n                        PIPService.shared.startPiP(size: pipSize)\n                    }\n                    .disabled((pipService.isPiPActive && !pipService.isKeepaliveMode) || isTestPiPActive)\n\n                    Button("[保活組]啟動 PiP 保活") {\n                        let pipSize = CGSize(width: 300, height: 200)\n                        PIPService.shared.startKeepalivePiP(size: pipSize)\n                    }\n                    .disabled(pipService.isPiPActive || isTestPiPActive)\n\n                    Button("[聊天室]停止 PiP") {\n                        PIPService.shared.stopPiP()\n                    }\n                    .disabled(!pipService.isPiPActive)\n                }'

if old in content:
    content = content.replace(old, new, 1)
    with open('C:\\Users\\agp05\\OneDrive\\桌面\\ReplyKit\\liveAPP\\PIPContent.swift.tmp', 'w', encoding='utf-8') as f:
        f.write(content)
    print('OK')
else:
    print('NOT FOUND')
