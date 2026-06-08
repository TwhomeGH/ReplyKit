@preconcurrency import Metal
import VideoToolbox
import CoreVideo
import CoreMedia
import simd

import Foundation
import AVFoundation
import Accelerate

import HaishinKit



// MARK: - Timestamp Debugger

final class TimestampDebugger {

    struct FrameInfo {
        let pts: CMTime
        let delta: Double   // ms
    }

    private var lastOriginal: FrameInfo?
    private var lastWrapped: FrameInfo?

    var enabled: Bool = RPConfig.shared.enableTimeDebug

    var logEveryNFrames: Int = 5   // 可改成 5 或 10 降低輸出量

    private var frameCount: Int = 0

    func log(originalTime: CMSampleTimingInfo, wrapped: CMSampleBuffer?) {

        guard enabled else { return }
        guard let wrapped else { return }

        frameCount += 1
        if frameCount % logEveryNFrames != 0 { return }

        let origPTS = originalTime.presentationTimeStamp
        let wrapPTS = CMSampleBufferGetPresentationTimeStamp(wrapped)

        let origDelta = delta(from: lastOriginal?.pts, to: origPTS)
        let wrapDelta = delta(from: lastWrapped?.pts, to: wrapPTS)

        lastOriginal = FrameInfo(pts: origPTS, delta: origDelta)
        lastWrapped  = FrameInfo(pts: wrapPTS, delta: wrapDelta)

        sendlog(message:"""
        🕒 Frame \(frameCount)
        ─ Original PTS: \(format(origPTS))  Δ: \(formatMS(origDelta))
        ─ Wrapped  PTS: \(format(wrapPTS))  Δ: \(formatMS(wrapDelta))
        ─ Drift (ms): \(formatMS((wrapPTS - origPTS).seconds * 1000))
        """)

    }

    private func delta(from: CMTime?, to: CMTime) -> Double {
        guard let from else { return 0 }
        return (to - from).seconds * 1000
    }

    private func format(_ time: CMTime) -> String {
        return String(format: "%.3f", time.seconds)
    }

    private func formatMS(_ ms: Double) -> String {
        return String(format: "%.2f ms", ms)
    }
}


// MARK: - GPU Video Rotator



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


    private var lastPTS: CMTime?
    
    private var cachedFormatDescription: CMVideoFormatDescription?
    private var cachedFormatSize: CGSize = .zero

    var originalTimeBAK: CMSampleTimingInfo?
    
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

    private let tsDebugger = TimestampDebugger()

    func tsDebug(_ on:Bool=false) {
        tsDebugger.enabled = on
    }

    private var pipelineBilinear: MTLComputePipelineState?
    private var pipelineBicubic: MTLComputePipelineState?

    private(set) var textureCache: CVMetalTextureCache?

    private var isActive = true

    var dstWW: Int = 0
    var dstHH: Int = 0
    var OutWW: Int = 0
    var OutHH: Int = 0

    var RotateOriginal = false

    var debug: Bool = false
    struct Params {
        var srcWidth: UInt32
        var srcHeight: UInt32
        var dstWidth: UInt32
        var dstHeight: UInt32
        var oDstW:UInt32
        var oDstH:UInt32
        var angle: UInt32
    }


    struct OutputKey: Hashable {
        let width: Int
        let height: Int
    }

    
    // 使用結構體作為 Dictionary 的 key
    private var outputPool: [OutputKey: [ReusableOutputSet]] = [:]
    private let outputPoolLock = NSLock()
    private let maxPoolSize: Int


    // 新增統一的 addToPool 方法
        func addToPool(width: Int, height: Int, set: ReusableOutputSet) {
            let key = OutputKey(width: width, height: height)
            outputPoolLock.lock()
            var pool = outputPool[key] ?? []
            pool.append(set)
            outputPool[key] = pool
            outputPoolLock.unlock()
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




    // LockedBox no longer needed, removed.

    // MARK: - ASync GPU semaphore
    actor AsyncSemaphore {
        private var capacity: Int
        private var available: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []

        struct Info {
                let now: Int
                let max: Int
        }

        // ✅ 不可變快照（整包替換）
        private var snapshot = Info(now: 0, max: 0)

        init(value: Int) {
            capacity = value
            available = value

            snapshot = Info(now: value, max: value)
        }


        func update(_ max:Int) {
            guard capacity != max else { return }
            capacity = max

            snapshot = Info(now: available, max: max)
            logger.debug("更新GPU等待上限:\(self.capacity)")

        }
        func wait() async {
            if available > 0 {
                available -= 1
                snapshot = Info(now: available,  max: capacity)
                return
            }

            await withTaskCancellationHandler(
                    operation: {
                        await withCheckedContinuation { cont in
                            waiters.append(cont)
                        }
                    },
                    onCancel: {
                        Task {
                            await removeCurrentContinuation()
                        }
                    }
                )

            // ✅ 被喚醒後，正式佔用一個 permit
            available -= 1
            snapshot = Info(now: available, max: capacity)




        }

        private func removeCurrentContinuation() {
            // 只移除當前被取消的 continuation，避免全部移除導致其他協程無法 resume
            if !waiters.isEmpty {
                _ = waiters.removeFirst()
            }
        }

        func signal() {
            if !waiters.isEmpty {
                let cont = waiters.removeFirst()
                cont.resume(returning: ())
            } else {
                available = min(available + 1, capacity)
            }

            snapshot = Info(now: available, max: capacity)
        }

        
        func info() -> Info {
            return snapshot
        }


        func reset() {

            waiters.removeAll()

            // 2️⃣ 重置容量

            available = capacity
            snapshot = Info(now: available, max: capacity)

        }
    }


    private let gpuSemaphore = AsyncSemaphore(value: 5)

    private let NGPUSemaphore = DispatchSemaphore(value: 10)
    

    func cleanup() async {
        guard isActive else { return }
        isActive = false   // 先阻止新 GPU 任務進來
        cleanupResources()
    }


    // MARK: - Cleanup
    func cleanupResources() {
    isActive = false
    hasMetalResources = false

    outputPoolLock.lock()
    for (_, pool) in outputPool {
        for outSet in pool {
            outSet.cvY = nil
            outSet.cvUV = nil
        }
    }
    outputPool.removeAll()
    outputPoolLock.unlock()

    if let cache = textureCache {
        CVMetalTextureCacheFlush(cache, 0)
    }
    textureCache = nil

    pipelineBilinear = nil
    pipelineBicubic = nil

    let poolCount = outputPool.count
    let bufferCount = outputPool.values.reduce(0) { $0 + $1.count }
    logTo("cleanup called - releasing \(poolCount) output pool(s), \(bufferCount) pooled buffer(s)")
}




    // MARK: Init
    init?(dstW: Int = 0, dstH: Int = 0,outW:Int=0, outH:Int=0, debug: Bool = false,
            maxPoolSize: Int = 10 , useBic:QualityMode = .live ,RotateOriginal:Bool = false ) {

        self.qualityMode = useBic
        self.dstWW = dstW
        self.dstHH = dstH
        self.OutWW = outW
        self.OutHH = outH
        self.debug = debug
        self.maxPoolSize = maxPoolSize

        self.RotateOriginal = RotateOriginal
        self.hasMetalResources = false


        sendlog(
            message:"GPU Rotator init:\(dstWW)x\(dstHH) Debug:\(debug) 使用:\(qualityMode) PoolSize:\(maxPoolSize)",
            flush: true
        )

    }

    var hasMetalResources = false

    private func ensureMetalResources() -> Bool {

        guard hasMetalResources == false else {
            return true
        }

        let ctx = MetalContext.shared

        // 1️⃣ TextureCache（共用 MetalContext）
        if textureCache == nil {
            textureCache = ctx.ensureTextureCache()
            if textureCache == nil {
                logTo("建立 TextureCache 失敗")
                return false
            }
        }

        // 2️⃣ 初始化「兩條」 ComputePipeline
        if pipelineBilinear == nil || pipelineBicubic == nil {
            if !buildComputePipeline() {
                logTo("建立 ComputePipeline 失敗")
                return false
            }
        }

        hasMetalResources = true
        return true

    }
    

    private func buildComputePipeline() -> Bool {
        do {
            let lib = MetalContext.shared.library

            // --- Pipeline A：直播（bilinear）---
            if pipelineBilinear == nil {
                guard let fn = lib.makeFunction(name: "rotateNV12_bilinear") else { return false }
                pipelineBilinear = try MetalContext.shared.device.makeComputePipelineState(function: fn)
            }

            // --- Pipeline B：高品質（bicubic）---
            if pipelineBicubic == nil {
                guard let fn = lib.makeFunction(name: "rotateNV12_bicubic") else { return false }
                pipelineBicubic = try MetalContext.shared.device.makeComputePipelineState(function: fn)
            }

            return true
        } catch {
            return false
        }
    }



    private func logTo(_ message: String) { if debug { sendlog(message: "[GPU Rotator] \(message)") } }


    var timing: CMSampleTimingInfo?
    
    private final class FrameContext:@unchecked Sendable {

        var timing: CMSampleTimingInfo
        let outPB: CVPixelBuffer
        let outSet: RPVideoRotatorNV12BatchQueueOptimized.ReusableOutputSet

        // ✅ 新增：撐住 input backing
        var inY: CVMetalTexture?
        var inUV: CVMetalTexture?


        init(timing:CMSampleTimingInfo,
            outSet: RPVideoRotatorNV12BatchQueueOptimized.ReusableOutputSet,
            inY:CVMetalTexture,
            inUV:CVMetalTexture
        ) {

            self.timing = timing
            self.outSet = outSet
            self.outPB = outSet.pixelBuffer

            self.inY = inY
            self.inUV = inUV

        }


    }



    func asyncWait(_ semaphore: DispatchSemaphore, timeout: DispatchTime) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let result = semaphore.wait(timeout: timeout)
                continuation.resume(returning: result)
            }
        }
    }


    // MARK: - Enqueue Frame
    func rotateAsync(sampleBuffer: CMSampleBuffer,originalTime: CMSampleTimingInfo, angle: RotationAngle) async -> CMSampleBuffer? {


         // 延遲初始化 Metal/TextureCache
        guard ensureMetalResources() else {
            return nil
        }

        

        // ✅ 🔥 先看 GPU 是否已滿
        // Task {

        // let info = await gpuSemaphore.info()
        // if info.now == 0 {
        //     // 👉 GPU 已滿，直接丟掉這幀（避免排隊造成大卡）
        //     logTo("GPU 滿載 可用Frame正在處理 丟幀")
        //     return
        // }

        // self.logTo("GPU Info:\(info.now):\(info.max) \(String(describing:self.timing))")

        // }

        
        //await gpuSemaphore.wait()
        //let res = await asyncWait(NGPUSemaphore, timeout: .now() + 0.2)// 加入超時，避免死鎖



        

        //defer {
        
            //釋放釋放資源
            
            
            //Task { await gpuSemaphore.signal() }


        //}

        timing = originalTime

        
        guard let inBuffer = sampleBuffer.imageBuffer else { 
            return nil 
        }
        let srcW = CVPixelBufferGetWidth(inBuffer)
        let srcH = CVPixelBufferGetHeight(inBuffer)
        var dstW = (
            angle == .landscapeRight || angle == .landscapeLeft
        ) ? srcH : srcW
        var dstH = (
            angle == .landscapeRight || angle == .landscapeLeft
        ) ? srcW : srcH


        if !RotateOriginal && OutWW > 0 && OutHH > 0  {
            dstW = OutWW; dstH = OutHH

            logTo("GPU進行輸出寬高調整:\(OutWW)x\(OutHH)")

        } else if dstWW > 0 && dstHH > 0 {
            logTo("GPU使用旋轉後寬高:\(dstWW)x\(dstHH)")
            dstW = dstWW
            dstH = dstHH
            
        } else {
            logTo("GPU使用原始寬高:\(dstW)x\(dstH) -> \(srcW)x\(srcH)")
        }




        self.logTo("\(srcW)x\(srcH) -> \(dstW)x\(dstH) angle:\(angle)")

        guard dstW > 0 && dstH > 0 else {
            logTo("無效的輸出維度: \(dstW)x\(dstH)，跳過此幀")
            return nil
        }
        guard let outSet = getReusableOutput(width: dstW, height: dstH) else { return nil }

        guard let ycvTexIn = makeTexture(from: inBuffer, planeIndex: 0),
            let uvcvTexIn = makeTexture(from: inBuffer, planeIndex: 1),
            let cmd = MetalContext.shared.queue.makeCommandBuffer() else {

            recycleOutput(outSet)

            // 必須釋放 semaphore，否則會 deadlock
            // Task {
            //     await gpuSemaphore.signal()
            // }

            

            return nil
        }

        renderPlaneYUV(cmd: cmd, srcY: ycvTexIn.tex, srcUV: uvcvTexIn.tex,
                        dstY: outSet.yTex, dstUV: outSet.uvTex, angle: angle)


        // Add a timeout to prevent hanging if cmd.addCompletedHandler is never called
        return await withCheckedContinuation { (cont: CheckedContinuation<CMSampleBuffer?, Never>) in

            var didResume = false
            

            let frameC = FrameContext(timing: originalTime, outSet: outSet,
                                        inY: ycvTexIn.cv, inUV: uvcvTexIn.cv
            )

            cmd.addCompletedHandler { [self] _ in
                guard !didResume else { return }
                didResume = true

                frameC.inY = nil
                frameC.inUV = nil

                let wrapped = self.wrapPixelBuffer(
                    frameC.outPB, timing: frameC.timing
                )

                if let wrapped {
                    self.tsDebugger.log(
                        originalTime: frameC.timing,
                        wrapped: wrapped
                    )
                }

                cont.resume(returning: wrapped)

                // ✅ semaphore 一定要在 GPU 真完成後 signal（現在位置正確）
                // Task {
                //     await self.gpuSemaphore.signal()
                // }

                

                self.recycleOutput(frameC.outSet)
                self.logTo("GPU Frame down :\(frameC.timing.presentationTimeStamp)s")
            }

            cmd.commit()
        }
    }


    

  // MARK: - Reusable Output
private func getReusableOutput(width: Int, height: Int) -> ReusableOutputSet? {
    guard isActive else { return nil }
    outputPoolLock.lock()
    defer { outputPoolLock.unlock() }

    let key = OutputKey(width: width, height: height)
    if var pool = outputPool[key], !pool.isEmpty {
        let set = pool.removeFirst()
        outputPool[key] = pool
        return set
    }

    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
    ]
    let status = CVPixelBufferCreate(nil, width, height,
                                     kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                     attrs as CFDictionary, &pb)
    guard status == kCVReturnSuccess, let pixelBuffer = pb else {
        logTo("CVPixelBufferCreate failed with status: \(status)")
        return nil
    }

    guard let yTex = makeTexture(from: pixelBuffer, planeIndex: 0),
          let uvTex = makeTexture(from: pixelBuffer, planeIndex: 1) else {
        
        return nil
    }

    return ReusableOutputSet(pixelBuffer: pixelBuffer,
                             yTex: yTex.tex,
                             uvTex: uvTex.tex,
                             cvY: yTex.cv,
                             cvUV: uvTex.cv,
                             lastUsed: Date())
}



    // MARK: - Recycle Output
    func recycleOutput(_ outSet: ReusableOutputSet) {
    guard isActive else {
        outSet.cvY = nil
        outSet.cvUV = nil
        return
    }
    let width = CVPixelBufferGetWidth(outSet.pixelBuffer)
    let height = CVPixelBufferGetHeight(outSet.pixelBuffer)
    let key = OutputKey(width: width, height: height)

    outputPoolLock.lock()

    var pool = outputPool[key] ?? []
    if pool.count >= maxPoolSize {
        let removed = pool.removeFirst()
        removed.cvY = nil
        removed.cvUV = nil
    }
    pool.append(outSet)
    outputPool[key] = pool

    outputPoolLock.unlock()
}



    func makeTexture(from pixelBuffer: CVPixelBuffer, planeIndex: Int) -> (cv: CVMetalTexture, tex: MTLTexture)? {
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


    /// Wraps a CVPixelBuffer into a CMSampleBuffer with the given timing info.
    /// - Parameters:
    ///   - pixelBuffer: The pixel buffer to wrap.
    ///   - timing: The timing information for the sample buffer.
    /// - Returns: A CMSampleBuffer containing the pixel buffer and timing, or nil on failure.
   private func wrapPixelBuffer(
    _ pixelBuffer: CVPixelBuffer,
    timing: CMSampleTimingInfo
) -> CMSampleBuffer? {

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let size = CGSize(width: width, height: height)

    // ✅ format cache
    if cachedFormatDescription == nil || cachedFormatSize != size {
        var formatDesc: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        if status == noErr, let fmt = formatDesc {
            cachedFormatDescription = fmt
            cachedFormatSize = size
        } else {
            sendlog(message: "CMVideoFormatDescriptionCreateForImageBuffer failed: \(status)")
            // ❌ 不要傳 nil，直接 fallback
            return fallbackSampleBuffer(pixelBuffer: pixelBuffer, timing: timing)
        }
    }

    guard let fmt = cachedFormatDescription else {
        sendlog(message: "No valid formatDescription available")
        return fallbackSampleBuffer(pixelBuffer: pixelBuffer, timing: timing)
    }

    var sampleBuffer: CMSampleBuffer?
    var timingInfo = timing

    let status = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: fmt,
        sampleTiming: &timingInfo,
        sampleBufferOut: &sampleBuffer
    )

    if status != noErr {
        sendlog(message: "CMSampleBufferCreateReadyWithImageBuffer failed: \(status)")
        return fallbackSampleBuffer(pixelBuffer: pixelBuffer, timing: timing)
    }

    return sampleBuffer
}

// MARK: - Fallback SampleBuffer
// 在 wrapPixelBuffer 失敗時使用，至少包裝 pixelBuffer，讓 pipeline 不會中斷

private func fallbackSampleBuffer(
    pixelBuffer: CVPixelBuffer,
    timing: CMSampleTimingInfo
) -> CMSampleBuffer? {
    var formatDesc: CMFormatDescription?
    let status = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDesc
    )
    guard status == noErr, let fmt = formatDesc else {
        sendlog(message: "Fallback also failed: \(status)")
        return nil
    }

    var sampleBuffer: CMSampleBuffer?
    var timingInfo = timing
    let createStatus = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: fmt,
        sampleTiming: &timingInfo,
        sampleBufferOut: &sampleBuffer
    )
    if createStatus != noErr {
        sendlog(message: "Fallback CMSampleBufferCreateReadyWithImageBuffer failed: \(createStatus)")
    }
    return sampleBuffer
}


    // MARK: - Render YUV
    func renderPlaneYUV(cmd: MTLCommandBuffer,
                        srcY: MTLTexture, srcUV: MTLTexture,
                        dstY: MTLTexture, dstUV: MTLTexture,
                        angle: RotationAngle) {

        guard let compute = (qualityMode == .live ? pipelineBilinear : pipelineBicubic),
            let encoder = cmd.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(compute)
        encoder.setTexture(srcY, index: 0)
        encoder.setTexture(srcUV, index: 1)
        encoder.setTexture(dstY, index: 2)
        encoder.setTexture(dstUV, index: 3)

        let tgWidth = min(compute.threadExecutionWidth, 32)
        let tgHeight = max(1, compute.maxTotalThreadsPerThreadgroup / tgWidth)


        var params = Params(srcWidth: UInt32(srcY.width), srcHeight: UInt32(srcY.height),
                            dstWidth: UInt32(dstY.width), dstHeight: UInt32(dstY.height),
                            oDstW: UInt32(OutWW), oDstH: UInt32(OutHH),
                            angle: UInt32(angle.rawValue))


        

        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)

        if OutWW > 0 && OutHH > 0 {
            logTo("GPU Shader 寬高 參數:\(OutWW)x\(OutHH)")
            encoder.dispatchThreads(MTLSize(width: OutWW, height: OutHH, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: tgWidth, height: tgHeight, depth: 1))

        } else {
            logTo("GPU Shader 寬高參數使用輸入尺寸:\(srcY.width)x\(srcY.height)")
            encoder.dispatchThreads(MTLSize(width: dstY.width, height: dstY.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: tgWidth, height: tgHeight, depth: 1))

        }



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

