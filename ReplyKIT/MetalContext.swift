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

        sendlog(message: "MetalContext: 初始化完成 \(device.name) unifiedMemory:\(device.hasUnifiedMemory) lowPower:\(device.isLowPower) headless:\(device.isHeadless) maxThreads:\(device.maxThreadsPerThreadgroup.width)x\(device.maxThreadsPerThreadgroup.height)x\(device.maxThreadsPerThreadgroup.depth)")
    }

    func ensureTextureCache() -> CVMetalTextureCache? {
        if textureCache == nil {
            var cache: CVMetalTextureCache?
            let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            textureCache = cache
            if status == kCVReturnSuccess, cache != nil {
                sendlog(message: "MetalContext: 重建 texture cache 成功")
            } else {
                sendlog(message: "MetalContext: 重建 texture cache 失敗 status:\(status)")
            }
        }
        return textureCache
    }

    func rebuildQueue() {
        guard let newQueue = device.makeCommandQueue() else {
            sendlog(message: "MetalContext: 重建 command queue 失敗")
            return
        }
        queue = newQueue
        textureCache = nil
        sendlog(message: "MetalContext: 重建 command queue + 清除 texture cache")
    }
}
