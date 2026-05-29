@preconcurrency import Metal
import CoreVideo

final class MetalContext: @unchecked Sendable {
    static let shared = MetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    var textureCache: CVMetalTextureCache?

    private init() {
        let dev = MTLCreateSystemDefaultDevice()!
        device = dev
        queue = dev.makeCommandQueue()!
        library = dev.makeDefaultLibrary()!

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, dev, nil, &cache)
        textureCache = cache

        sendlog(message: "MetalContext: 初始化完成 \(device.name)")
    }

    func ensureTextureCache() -> CVMetalTextureCache? {
        if textureCache == nil {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            textureCache = cache
        }
        return textureCache
    }
}
