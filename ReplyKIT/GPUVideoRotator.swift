@preconcurrency import Metal
import VideoToolbox
import CoreVideo
import CoreMedia
import simd

import Foundation
import AVFoundation
import Accelerate

import HaishinKit







// MARK: - GPU Video Rotator
//
//final class ReusableBuffer {
//    let pixelBuffer: CVPixelBuffer
//    var inUse: Bool = false
//    var yTex: MTLTexture?
//    var uTex: MTLTexture?
//    var vTex: MTLTexture?
//
//    init(pixelBuffer: CVPixelBuffer) {
//        self.pixelBuffer = pixelBuffer
//    }
//}


enum RotationAngle: UInt32, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case portrait = 0          // 直向
    case landscapeRight = 90   // 橫向，Home鍵右側
    case portraitUpsideDown = 180 // 反向直向
    case landscapeLeft = 270   // 橫向，Home鍵左側

    var id: UInt32 { rawValue }


    var description: String {
        switch self {
        case .portrait: return "直向"
        case .landscapeRight: return "橫向  (Home鍵在右側)"
        case .portraitUpsideDown: return "反向直向"
        case .landscapeLeft: return "橫向 (Home鍵在左側)"
        }
    }
}



// MARK: - Safe Batch Video Rotator (Async/Await)
final class RPVideoRotatorNV12BatchQueueOptimized: @unchecked Sendable {


    enum QualityMode: CustomStringConvertible {
        case live      // bilinear
        case quality   // bicubic

        var description: String {
            switch self {
            case .live:    return "Live (Bilinear)"
            case .quality: return "Quality (Bicubic)"
            }
        }

    }

    var qualityMode: QualityMode = .live


    private var device: MTLDevice?
    private var queue: MTLCommandQueue?

    private var pipelineBilinear: MTLComputePipelineState?
    private var pipelineBicubic: MTLComputePipelineState?

    private(set) var textureCache: CVMetalTextureCache?

    private var isActive = true
    var dstWW: Int = 0
    var dstHH: Int = 0
    var debug: Bool = false
    struct Params {
        var srcWidth: UInt32
        var srcHeight: UInt32
        var dstWidth: UInt32
        var dstHeight: UInt32
        var angle: UInt32
    }

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

    
    // MARK: - ASync GPU semaphore
    actor AsyncSemaphore {
        private let capacity: Int
        private var available: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(value: Int) {
            self.capacity = value
            self.available = value
        }

        func wait() async {
            if available > 0 {
                available -= 1
                return
            }

            await withCheckedContinuation { cont in
                waiters.append(cont)
            }
        }

        func signal() {
            if !waiters.isEmpty {
                let cont = waiters.removeFirst()
                cont.resume()
            } else {
                available = min(available + 1, capacity)
            }
        }

        func reset() {
            available = capacity
            waiters.removeAll()
        }
    }

    private let gpuSemaphore = AsyncSemaphore(value: 3)



    func cleanup() async {
        guard isActive else { return }
        isActive = false   // 先阻止新 GPU 任務進來
        cleanupD()
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

        pipelineBilinear = nil
        pipelineBicubic = nil

        logTo("cleanup called")
    }

    // MARK: Init
    init?(dstW: Int = 0, dstH: Int = 0, debug: Bool = false,
          maxPoolSize: Int = 3 , useBic:QualityMode = .live) {

        self.qualityMode = useBic
        self.dstWW = dstW
        self.dstHH = dstH
        self.debug = debug
        self.maxPoolSize = maxPoolSize

        sendlog(
            message:"GPU Rotator init:\(dstWW)x\(dstHH) Debug:\(debug) 使用:\(qualityMode)",
            flush: true
        )

    }

    private func ensureMetalResources() -> Bool {
        // 1️⃣ 初始化 MTLDevice + CommandQueue
        if queue == nil {
            guard let dev = MTLCreateSystemDefaultDevice(),
                  let q = dev.makeCommandQueue() else { return false }
            device = dev
            queue = q
        }

        // 2️⃣ 初始化 TextureCache
        if textureCache == nil {
            guard let dev = device,
                  CVMetalTextureCacheCreate(
                    nil,
                    nil,
                    dev,
                    nil,
                    &textureCache
                  ) == kCVReturnSuccess,
                  textureCache != nil else { return false }
        }

        // 3️⃣ 初始化「兩條」 ComputePipeline
        // ❗只要任一條還沒建，就建一次
        if pipelineBilinear == nil || pipelineBicubic == nil {
            if !buildComputePipeline() { return false }
        }

        return true
    }
    

    private func buildComputePipeline() -> Bool {
        do {
            guard let dev = device,
                  let lib = dev.makeDefaultLibrary() else { return false }

            // --- Pipeline A：直播（bilinear）---
            if pipelineBilinear == nil {
                guard let fn = lib.makeFunction(name: "rotateNV12_bilinear") else { return false }
                pipelineBilinear = try dev.makeComputePipelineState(function: fn)
            }

            // --- Pipeline B：高品質（bicubic）---
            if pipelineBicubic == nil {
                guard let fn = lib.makeFunction(name: "rotateNV12_bicubic") else { return false }
                pipelineBicubic = try dev.makeComputePipelineState(function: fn)
            }

            return true
        } catch {
            return false
        }
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
        guard ensureMetalResources() else {
            return nil
        }


        guard let inBuffer = sampleBuffer.imageBuffer else { return nil }
        let srcW = CVPixelBufferGetWidth(inBuffer)
        let srcH = CVPixelBufferGetHeight(inBuffer)
        var dstW = (
            angle == .landscapeRight || angle == .landscapeLeft
        ) ? srcH : srcW
        var dstH = (
            angle == .landscapeRight || angle == .landscapeLeft
        ) ? srcW : srcH


        if !RPConfig.shared.RotateOriginal && dstWW > 0 && dstHH > 0 {
            dstW = dstWW; dstH = dstHH

            logTo("GPU進行寬高調整:\(dstWW)x\(dstWW)")
        } else {
            logTo("GPU使用原始寬高:\(srcW)x\(srcH)")
        }


        //        let infoGPU=await gpuSemaphore.info()
        //        self.logTo("GPU Info:\(infoGPU.now):\(infoGPU.max)")

        self.logTo("\(srcW)x\(srcH) -> \(dstW)x\(dstH) angle:\(angle)")

        guard let outSet = getReusableOutput(width: dstW, height: dstH) else { return nil }
        guard let ycvTexIn = makeTexture(from: inBuffer, planeIndex: 0),
              let uvcvTexIn = makeTexture(from: inBuffer, planeIndex: 1),
              let cmd = queue?.makeCommandBuffer() else {

            recycleOutput(outSet)

            return nil
        }

        renderPlaneYUV(cmd: cmd, srcY: ycvTexIn.tex, srcUV: uvcvTexIn.tex,
                       dstY: outSet.yTex, dstUV: outSet.uvTex, angle: angle)



        return await withCheckedContinuation { (cont: CheckedContinuation<CMSampleBuffer?, Never>) in

            let frameC = FrameContext(sampleBuffer: sampleBuffer, outSet: outSet,
                                      inY: ycvTexIn.cv,inUV: uvcvTexIn.cv
            )

            cmd.addCompletedHandler { _ in
                let wrapped = self.wrapPixelBuffer(
                    frameC.outPB
                )

                cont.resume(returning: wrapped)

                // ✅ semaphore 一定要在 GPU 真完成後 signal（現在位置正確）
                Task {
                    await self.gpuSemaphore.signal()
                }

                self.logTo("GPU Frame down")

                self.recycleOutput(frameC.outSet)


            }
            cmd.commit()
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

        outSet.lastUsed = Date()
        let removed: ReusableOutputSet?

        outputPoolLock.lock()

        if outputPool.count >= maxPoolSize {

            removed = outputPool.removeFirst()
            outputPool.append(outSet)

        } else {
            removed = nil
            outputPool.append(outSet)
        }

        outputPoolLock.unlock()

        removed?.cvY = nil
        removed?.cvUV = nil

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

    private func wrapPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {

        let pts = CMClockGetTime(CMClockGetHostTimeClock())

        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: CMTime.invalid
        )

        var formatDesc: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        ) == noErr,
        let fmt = formatDesc else { return nil }

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmt,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr else { return nil }
        return sampleBuffer
    }


    // MARK: - Render YUV
    private func renderPlaneYUV(cmd: MTLCommandBuffer,
                                srcY: MTLTexture, srcUV: MTLTexture,
                                dstY: MTLTexture, dstUV: MTLTexture,
                                angle: RotationAngle) {


        let pipeline: MTLComputePipelineState?

        switch qualityMode {
        case .live:
            pipeline = pipelineBilinear
        case .quality:
            pipeline = pipelineBicubic
        }

        guard let compute = pipeline,
              let encoder = cmd.makeComputeCommandEncoder() else { return }



        encoder.setComputePipelineState(compute)

        encoder.setTexture(srcY, index: 0)
        encoder.setTexture(srcUV, index: 1)
        encoder.setTexture(dstY, index: 2)
        encoder.setTexture(dstUV, index: 3)

        let tgWidth = min(compute.threadExecutionWidth, 16)
        let tgHeight = max(1, compute.maxTotalThreadsPerThreadgroup / tgWidth)

        var params = Params(srcWidth: UInt32(srcY.width), srcHeight: UInt32(srcY.height),
                            dstWidth: UInt32(dstY.width), dstHeight: UInt32(dstY.height),
                            angle: UInt32(angle.rawValue)
                            )

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





