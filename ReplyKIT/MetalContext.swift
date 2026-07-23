@preconcurrency import Metal
import CoreVideo

final class MetalContext: @unchecked Sendable {
    static var shared = MetalContext()

    let device: MTLDevice
    private(set) var queue: MTLCommandQueue
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

    func rebuildQueue() {
        queue = device.makeCommandQueue()!
        textureCache = nil
        sendlog(message: "MetalContext: 重建 command queue + 清除 texture cache")
    }
}
