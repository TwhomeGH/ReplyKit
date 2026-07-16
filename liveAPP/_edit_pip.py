import re

with open('C:\\Users\\agp05\\OneDrive\\桌面\\ReplyKit\\liveAPP\\PIPService.swift.tmp', 'r', encoding='utf-8') as f:
    content = f.read()

old = '    // MARK: - Attach displayLayer\n    private func attachToForegroundWindow'

method = '''
    @MainActor
    func startKeepalivePiP(size: CGSize = CGSize(width: 300, height: 200)) {
        stopPiP()
        isKeepaliveMode = true
        setupAudioSession()

        self.frameSize = size

        let pixelSize = CGSize(
            width: size.width * UIScreen.main.scale,
            height: size.height * UIScreen.main.scale
        )
        self.OframeSize = pixelSize

        setupPixelBufferPool(size: pixelSize)

        self.frameCount = 0
        currentFPS = keepaliveFPS

        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        self.displayLayer = layer

        self.pipController = AVPictureInPictureController(
            contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self.dummyDelegate)
        )
        self.pipController?.requiresLinearPlayback = false
        self.pipController?.setValue(1, forKey: "controlsStyle")
        self.pipController?.delegate = self

        self.attachToForegroundWindow {
            PIPLogTo("Keepalive PiP started")
            Task { @MainActor in
                self.startRenderTimer()
            }
        }
    }
'''

new = method + old

if old in content:
    content = content.replace(old, new, 1)
    with open('C:\\Users\\agp05\\OneDrive\\桌面\\ReplyKit\\liveAPP\\PIPService.swift.tmp', 'w', encoding='utf-8') as f:
        f.write(content)
    print('OK - method inserted')
else:
    print('NOT FOUND')
    # Show context around where we expect the match
    idx = content.find('// MARK: - Attach displayLayer')
    if idx >= 0:
        print(content[idx:idx+200])
