import Metal
import CoreVideo

final class PIPMetalRenderer {
    static let shared = PIPMetalRenderer()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let textureCache: CVMetalTextureCache

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            sendlog(message: "Metal 初始化失敗")
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, device, nil, &cache
        )
        guard status == kCVReturnSuccess, let cache = cache else {
            sendlog(message: "CVMetalTextureCache 建立失敗: \(status)")
            return nil
        }
        self.textureCache = cache
    }

    /// GPU clear：將 CVPixelBuffer 填入黑色，不需 CPU memset
    func clear(pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture = cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            return
        }

        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = texture
        desc.colorAttachments[0].loadAction = .clear
        desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: desc) else {
            return
        }
        encoder.endEncoding()
        cmdBuf.commit()
    }
}
