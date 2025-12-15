@preconcurrency import Metal
import VideoToolbox
import CoreVideo
import CoreMedia
import simd

import Foundation
import AVFoundation
import Accelerate

import HaishinKit



// MARK: - CVPixelBuffer InUse Extension
private extension CVPixelBuffer {
    private static var _inUseKey: UInt8 = 0

    var inUse: Bool {
        get { objc_getAssociatedObject(self, &CVPixelBuffer._inUseKey) as? Bool ?? false }
        set { objc_setAssociatedObject(self, &CVPixelBuffer._inUseKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

extension DispatchSemaphore {
    func waitAsync() async {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                self.wait()
                cont.resume()
            }
        }
    }
}

// MARK: - GPU Video Rotator

final class ReusableBuffer {
    let pixelBuffer: CVPixelBuffer
    var inUse: Bool = false
    var yTex: MTLTexture?
    var uTex: MTLTexture?
    var vTex: MTLTexture?

    init(pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
    }
}



// MARK: - Safe Batch Video Rotator (Async/Await)
final class RPVideoRotatorNV12BatchQueueOptimized: @unchecked Sendable {

    enum RotationAngle: UInt32, CaseIterable { case angle0 = 0, angle90 = 90, angle180 = 180, angle270 = 270 }

    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var computePipeline: MTLComputePipelineState!
    private(set) var textureCache: CVMetalTextureCache?

    private var isActive = true
    var mediaMixer: MediaMixer
    var dstWW: Int = 0
    var dstHH: Int = 0
    var useBic: Bool = true
    var debug: Bool = false
    struct Params { var srcWidth, srcHeight, dstWidth, dstHeight, angle, useBicubic, tileWidth, tileHeight: UInt32 }

    // MARK: - Metal Output Pool
    final class ReusableOutputSet {
        let pixelBuffer: CVPixelBuffer
        let yTex: MTLTexture
        let uvTex: MTLTexture
        var lastUsed: Date
        var cvY: CVMetalTexture?
        var cvUV: CVMetalTexture?

        init(pixelBuffer: CVPixelBuffer, yTex: MTLTexture, uvTex: MTLTexture,
             cvY: CVMetalTexture? = nil, cvUV: CVMetalTexture? = nil, lastUsed: Date = Date()) {
            self.pixelBuffer = pixelBuffer
            self.yTex = yTex
            self.uvTex = uvTex
            self.cvY = cvY
            self.cvUV = cvUV
            self.lastUsed = lastUsed
        }
    }

    private var outputPool: [ReusableOutputSet] = []
    private let outputPoolLock = NSLock()
    private let maxPoolSize: Int

    // MARK: Async-safe GPU semaphore
    actor AsyncSemaphore {
        private var availableCount: Int
        private var capacity: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init() {

            // 用 Metal device 名稱推估性能
            let device = MTLCreateSystemDefaultDevice()
            let name = device?.name.lowercased() ?? ""

            // 簡單、有效、無副作用的判定
            if name.contains("m2") || name.contains("m3") || name.contains("a17") {
                // 高階/新款 → 4
                self.availableCount = 4
                self.capacity = 4
            } else {

                self.availableCount = 3
                // 中階/老款 → 3
                self.capacity = 3
            }


//            self.availableCount = initialAvailable
//            self.capacity = capacity

        }

        func info() -> (now:Int,max:Int){
            return (now:self.availableCount,max:self.capacity)
        }

        // 延遲初始化時重新設定建議值
        func configure(initialAvailable: Int, capacity: Int) {
            self.capacity = max(1, capacity)

            // 只有在沒有 waiters 時才調整 availableCount
            if waiters.isEmpty {
                availableCount = min(max(0, initialAvailable), self.capacity)
            } else {
                // 若有人在等，讓 wait 流程照舊，不硬調 availableCount
                availableCount = min(availableCount, self.capacity)
            }
        }

        func wait() async {
            if availableCount > 0 { availableCount -= 1; return }
            await withCheckedContinuation { cont in waiters.append(cont) }
        }

        func signal() {
            if !waiters.isEmpty { waiters.removeFirst().resume() }
            else { availableCount = min(availableCount + 1, capacity) }
        }

        func waitUntilAllReleased() async {
            while availableCount < capacity { await Task.yield() }
        }
    }

    private let gpuSemaphore = AsyncSemaphore()



    func cleanup() {
        Task { [weak self] in
            guard let self else { return }
            await self.cleanGPU()
            self.cleanupD()
        }
    }

    func cleanGPU() async {
        // 等待所有 in-flight GPU 完成
        await gpuSemaphore.waitUntilAllReleased()
    }
    // MARK: - Cleanup
    func cleanupD() {
        isActive = false



        // 清空 pool，釋放 CVMetalTexture
        outputPoolLock.lock()
        for outSet in outputPool {
            outSet.cvY = nil
            outSet.cvUV = nil
        }
        outputPool.removeAll()
        outputPoolLock.unlock()

        // 清空 TextureCache
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
        textureCache = nil
        queue = nil
        computePipeline = nil

        logTo("cleanup called")
    }

    // MARK: Init
    init?(dstW: Int = 0, dstH: Int = 0, useBic: Bool = true, debug: Bool = false,
          maxPoolSize: Int = 3, mediaMixer: MediaMixer) {


        self.dstWW = dstW
        self.dstHH = dstH
        self.useBic = useBic
        self.debug = debug
        self.maxPoolSize = maxPoolSize
        self.mediaMixer = mediaMixer


    }

    private func ensureMetalResources() -> Bool {
        // 初始化 MTLDevice + CommandQueue
        if self.queue == nil {
            guard let dev = MTLCreateSystemDefaultDevice(),
                  let q = dev.makeCommandQueue() else { return false }
            self.device = dev
            self.queue = q
        }

        // 初始化 TextureCache
        if textureCache == nil {
            guard let dev = device, CVMetalTextureCacheCreate(
                nil,
                nil,
                dev,
                nil,
                &textureCache
            ) == kCVReturnSuccess,
                  textureCache != nil else { return false }
        }

        // 初始化 ComputePipeline
        if computePipeline == nil, !buildComputePipeline() {
            return false
        }

        return true
    }


    private func buildComputePipeline() -> Bool {
        do {
            guard let dev = device ,let lib = dev.makeDefaultLibrary(),
                  let kernel = lib.makeFunction(name: "rotateNV12_tileBicubicUV") else { return false }
            computePipeline = try dev.makeComputePipelineState(function: kernel)
            return true
        } catch { return false }
    }

    private func logTo(_ message: String) { if debug { sendlog(message: "[GPU Rotator] \(message)") } }


    private final class FrameContext:@unchecked Sendable {
        let sampleBuffer: CMSampleBuffer
        let outPB: CVPixelBuffer
        let outSet: RPVideoRotatorNV12BatchQueueOptimized.ReusableOutputSet

        // ✅ 新增：撐住 input backing
         let inY: CVMetalTexture
         let inUV: CVMetalTexture


        init(sampleBuffer: CMSampleBuffer,
             outSet: RPVideoRotatorNV12BatchQueueOptimized.ReusableOutputSet,
             inY:CVMetalTexture,
             inUV:CVMetalTexture
        ) {
            self.sampleBuffer = sampleBuffer
            self.outSet = outSet
            self.outPB = outSet.pixelBuffer

            self.inY = inY
            self.inUV = inUV

        }


    }

    let timeoutNs: UInt64 = 2_000_000_000


    // MARK: - Enqueue Frame
    func rotateAsync(sampleBuffer: CMSampleBuffer, angle: RotationAngle) async -> CMSampleBuffer? {
            await gpuSemaphore.wait()


        // 延遲初始化 Metal/TextureCache
        guard ensureMetalResources() else { return nil }


        guard let inBuffer = sampleBuffer.imageBuffer else { return nil }
        let srcW = CVPixelBufferGetWidth(inBuffer)
        let srcH = CVPixelBufferGetHeight(inBuffer)
        var dstW = (angle == .angle90 || angle == .angle270) ? srcH : srcW
        var dstH = (angle == .angle90 || angle == .angle270) ? srcW : srcH
        if dstWW > 0 && dstHH > 0 { dstW = dstWW; dstH = dstHH }


        //        let infoGPU=await gpuSemaphore.info()
        //        self.logTo("GPU Info:\(infoGPU.now):\(infoGPU.max)")

        self.logTo("\(srcW)x\(srcH) -> \(dstW)x\(dstH)")

        guard let outSet = getReusableOutput(width: dstW, height: dstH) else { return nil }
        guard let ycvTexIn = makeTexture(from: inBuffer, planeIndex: 0),
              let uvcvTexIn = makeTexture(from: inBuffer, planeIndex: 1),
              let cmd = queue?.makeCommandBuffer() else { return nil }

        renderPlaneYUV(cmd: cmd, srcY: ycvTexIn.tex, srcUV: uvcvTexIn.tex,
                       dstY: outSet.yTex, dstUV: outSet.uvTex, angle: angle)



//        return await withCheckedContinuation { cont in
//
//            let frameC = FrameContext(sampleBuffer: sampleBuffer, outSet: outSet,
//                                      inY: ycvTexIn.cv,inUV: uvcvTexIn.cv
//            )
//
//            cmd.addCompletedHandler { _ in
//                let wrapped = self.wrapPixelBuffer(
//                    frameC.outPB,
//                    originalSampleBuffer: sampleBuffer
//                )
//                self.recycleOutput(frameC.outSet)
//
//                self.logTo("GPU Frame down")
//                cont.resume(returning: wrapped)
//            }
//            cmd.commit()
//        }


        return await withCheckedContinuation { cont in
            let lock = NSLock()
            var didResume = false

            func resumeOnce(_ value: CMSampleBuffer?) {
                lock.lock()
                defer { lock.unlock() }
                if didResume { return }
                didResume = true
                cont.resume(returning: value)
            }

            let frameC = FrameContext(
                sampleBuffer: sampleBuffer,
                outSet: outSet,
                inY: ycvTexIn.cv,
                inUV: uvcvTexIn.cv
            )

            cmd.addCompletedHandler { _ in
                let wrapped = self.wrapPixelBuffer(frameC.outPB, originalSampleBuffer: sampleBuffer)

                // ✅ GPU 完成：回收 + signal（只會走一次）
                self.logTo("Frame Done")
                self.recycleOutput(frameC.outSet)
                Task { await self.gpuSemaphore.signal() }

                resumeOnce(wrapped)
            }

            cmd.commit()

            Task {
                try? await Task.sleep(nanoseconds: self.timeoutNs)

                // ✅ timeout：只「提早回 nil」，但不回收、不 signal（等 GPU 真完成再做）
                resumeOnce(nil)
            }
        }

    }

    // MARK: - Reusable Output
    private func getReusableOutput(width: Int, height: Int) -> ReusableOutputSet? {
        outputPoolLock.lock()
        defer { outputPoolLock.unlock() }

        if let idx = outputPool.firstIndex(where: { CVPixelBufferGetWidth($0.pixelBuffer) == width &&
                                                    CVPixelBufferGetHeight($0.pixelBuffer) == height }) {
            let set = outputPool.remove(at: idx)
            set.lastUsed = Date()
            return set
        }

        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs as CFDictionary, &pb)
        guard let pixelBuffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0), 0,
               CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) * CVPixelBufferGetHeightOfPlane(pixelBuffer, 0))
        memset(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1), 128,
               CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) * CVPixelBufferGetHeightOfPlane(pixelBuffer, 1))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        guard let yTex = makeTexture(from: pixelBuffer, planeIndex: 0),
              let uvTex = makeTexture(from: pixelBuffer, planeIndex: 1) else { return nil }

        return ReusableOutputSet(pixelBuffer: pixelBuffer, yTex: yTex.tex, uvTex: uvTex.tex,
                                 cvY: yTex.cv, cvUV: uvTex.cv, lastUsed: Date())
    }

    private func recycleOutput(_ outSet: ReusableOutputSet) {
        outputPoolLock.lock()
        defer { outputPoolLock.unlock() }

        outSet.lastUsed = Date()
        while outputPool.count >= maxPoolSize {
            let removed = outputPool.removeFirst()
            removed.cvY = nil
            removed.cvUV = nil
//            removed.pixelBuffer = nil
//            removed.uvTex = nil
//            removed.yTex = nil
        }
        outputPool.append(outSet)
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer, planeIndex: Int) -> (cv: CVMetalTexture, tex: MTLTexture)? {
        guard let cache = textureCache else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        let pixelFormat: MTLPixelFormat = (planeIndex == 0) ? .r8Unorm : .rg8Unorm

        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil,
                                                               pixelFormat, width, height, planeIndex, &cvTex)
        guard status == kCVReturnSuccess, let cv = cvTex, let tex = CVMetalTextureGetTexture(cv) else { return nil }
        return (cv: cv, tex: tex)
    }

    private func wrapPixelBuffer(_ pixelBuffer: CVPixelBuffer, originalSampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        var timingInfo = CMSampleTimingInfo.invalid
        CMSampleBufferGetSampleTimingInfo(originalSampleBuffer, at: 0, timingInfoOut: &timingInfo)

        var formatDesc: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                           imageBuffer: pixelBuffer,
                                                           formatDescriptionOut: &formatDesc) == noErr,
              let fmt = formatDesc else { return nil }

        var newBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: pixelBuffer,
                                                 dataReady: true,
                                                 makeDataReadyCallback: nil,
                                                 refcon: nil,
                                                 formatDescription: fmt,
                                                 sampleTiming: &timingInfo,
                                                 sampleBufferOut: &newBuffer) == noErr else { return nil }
        return newBuffer
    }

    // MARK: - Render YUV
    private func renderPlaneYUV(cmd: MTLCommandBuffer,
                                srcY: MTLTexture, srcUV: MTLTexture,
                                dstY: MTLTexture, dstUV: MTLTexture,
                                angle: RotationAngle) {

        guard let compute = computePipeline, let encoder = cmd.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(compute)
        encoder.setTexture(srcY, index: 0)
        encoder.setTexture(srcUV, index: 1)
        encoder.setTexture(dstY, index: 2)
        encoder.setTexture(dstUV, index: 3)

        let tgWidth = min(compute.threadExecutionWidth, 32)
        let tgHeight = max(1, compute.maxTotalThreadsPerThreadgroup / tgWidth)

        var params = Params(srcWidth: UInt32(srcY.width), srcHeight: UInt32(srcY.height),
                            dstWidth: UInt32(dstY.width), dstHeight: UInt32(dstY.height),
                            angle: UInt32(angle.rawValue), useBicubic: useBic ? 1 : 0,
                            tileWidth: UInt32(tgWidth), tileHeight: UInt32(tgHeight))

        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: dstY.width, height: dstY.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: tgWidth, height: tgHeight, depth: 1))
        encoder.endEncoding()
    }
}




// 安全陣列取值
extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}


// 擴展：快速建立 CVMetalTextureCache
extension CVMetalTextureCache {
    static func create(device: MTLDevice) throws -> CVMetalTextureCache {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let texCache = cache else { throw NSError() }
        return texCache
    }
}





