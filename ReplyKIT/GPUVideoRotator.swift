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


    private var cachedFormatDescription: CMVideoFormatDescription?
    private var cachedFormatSize: CGSize = .zero
    
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



    final class LockedBox<T> {
        private var value: T
        private let lock = NSLock()

        init(_ value: T) {
            self.value = value
        }

        func get() -> T {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ newValue: T) {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

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
        private nonisolated let snapshot = LockedBox(Info(now: 0, max: 0))

        init(value: Int) {
            capacity = value
            available = value

            snapshot.set(Info(now: value, max: value))
        }


        func update(_ max:Int) {
            guard capacity != max && capacity > 2 else { return }
            capacity = max

            snapshot.set(Info(now: available, max: max))
            logger.debug("更新GPU等待上限:\(self.capacity)")

        }
        func wait() async {
            if available > 0 {
                available -= 1
                snapshot.set(Info(now: available,  max: capacity))
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
            snapshot.set(Info(now: available, max: capacity))




        }

        private func removeCurrentContinuation() {
            // 取消等待：只移除，不放行
            waiters.removeAll()
        }

        func signal() {
            if !waiters.isEmpty {
                let _ = waiters.removeFirst()
                
            } else {
                available = min(available + 1, capacity)

            }

            snapshot.set(Info(now: available, max: capacity))
        }

        nonisolated func info() -> Info {
                snapshot.get()
            }


        func reset() {

            waiters.removeAll()

            // 2️⃣ 重置容量

            available = capacity
            snapshot.set(Info(now: available, max: capacity))

        }
    }


    private let gpuSemaphore = AsyncSemaphore(value: 5)

    private let audioProcess: AudioProcessor


    func cleanup() async {
        guard isActive else { return }
        isActive = false   // 先阻止新 GPU 任務進來
        cleanupD()
    }


    // MARK: - Cleanup
    func cleanupD() {
        isActive = false
        isMetalResources = false



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
          maxPoolSize: Int = 10 , useBic:QualityMode = .live,audioProcess:AudioProcessor) {

        self.qualityMode = useBic
        self.dstWW = dstW
        self.dstHH = dstH
        self.debug = debug
        self.maxPoolSize = maxPoolSize

        self.audioProcess = audioProcess

        isMetalResources = false


        sendlog(
            message:"GPU Rotator init:\(dstWW)x\(dstHH) Debug:\(debug) 使用:\(qualityMode) PoolSize:\(maxPoolSize)",
            flush: true
        )

    }

    var isMetalResources = false

    private func ensureMetalResources() -> Bool {

        guard isMetalResources == false else {
            return true
        }

        isMetalResources = true

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




    // MARK: - Enqueue Frame
    func rotateAsync(sampleBuffer: CMSampleBuffer, angle: RotationAngle) async -> CMSampleBuffer? {


         // 延遲初始化 Metal/TextureCache
        guard ensureMetalResources() else {
            return nil
        }

        

        // ✅ 🔥 先看 GPU 是否已滿
        let info = gpuSemaphore.info()
        if info.now == 0 {
            // 👉 GPU 已滿，直接丟掉這幀（避免排隊造成大卡）
            logTo("GPU 滿載 可用Frame正在處理 丟幀")
            return nil
        }

        
        await gpuSemaphore.wait()

        defer {
            //釋放釋放資源
            Task { await gpuSemaphore.signal() }
        }

       


        guard let inBuffer = sampleBuffer.imageBuffer else { 
            await gpuSemaphore.signal()
                                                          
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


        if !RPConfig.shared.RotateOriginal && dstWW > 0 && dstHH > 0 {
            dstW = dstWW; dstH = dstHH

            logTo("GPU進行寬高調整:\(dstWW)x\(dstHH)")
        } else {
            logTo("GPU使用原始寬高:\(srcW)x\(srcH)")
        }


        let infoGPU=gpuSemaphore.info()
        
        self.logTo("GPU Info:\(infoGPU.now):\(infoGPU.max)")
        self.logTo("\(srcW)x\(srcH) -> \(dstW)x\(dstH) angle:\(angle)")

        guard let outSet = getReusableOutput(width: dstW, height: dstH) else { return nil }
        guard let ycvTexIn = makeTexture(from: inBuffer, planeIndex: 0),
              let uvcvTexIn = makeTexture(from: inBuffer, planeIndex: 1),
              let cmd = queue?.makeCommandBuffer() else {

            recycleOutput(outSet)

            Task {
            await gpuSemaphore.signal()
            }

            return nil
        }

        renderPlaneYUV(cmd: cmd, srcY: ycvTexIn.tex, srcUV: uvcvTexIn.tex,
                       dstY: outSet.yTex, dstUV: outSet.uvTex, angle: angle)



        return await withCheckedContinuation { (cont: CheckedContinuation<CMSampleBuffer?, Never>) in

            var timing = CMSampleTimingInfo()

            // ✅ 用系統時間當 PTS（避免 GPU 延遲影響）
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            timing.presentationTimeStamp = now

            audioProcessor.updateVideoPTS(now)
                                              
            CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing)
            let frameC = FrameContext(timing: timing, outSet: outSet,
                                      inY: ycvTexIn.cv,inUV: uvcvTexIn.cv
            )


            cmd.addCompletedHandler { _ in

                
                CVPixelBufferLockBaseAddress(frameC.outPB, [])
                CVPixelBufferUnlockBaseAddress(frameC.outPB, [])
                                     
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
                Task {
                    await self.gpuSemaphore.signal()
                    
                }
                self.recycleOutput(frameC.outSet)
                self.logTo("GPU Frame down")
                

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


    private func wrapPixelBuffer(
    _ pixelBuffer: CVPixelBuffer,
    timing: CMSampleTimingInfo
) -> CMSampleBuffer? {

    var timing = timing

    // ✅ 用系統時間當 PTS（避免 GPU 延遲影響）
    let now = CMClockGetTime(CMClockGetHostTimeClock())
    timing.presentationTimeStamp = now

    // 👉 duration 建議補一下（避免 encoder 猜錯）
    //if timing.duration == .invalid {
    //    timing.duration = CMTime(value: 1, timescale: 60) // 60fps
    //}
    //移交給原來的處理

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let size = CGSize(width: width, height: height)

    // ✅ format cache 
    if cachedFormatDescription == nil || cachedFormatSize != size {
        var formatDesc: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        ) == noErr,
        let fmt = formatDesc else {
            return nil
        }

        cachedFormatDescription = fmt
        cachedFormatSize = size
    }

    guard let fmt = cachedFormatDescription else { return nil }

    // ✅ 這行是關鍵（替換掉原本的）
    var sampleBuffer: CMSampleBuffer?

    let status = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: fmt,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    )

    guard status == noErr else { return nil }

    return sampleBuffer
}
    

    private func oldwrapPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        timing: CMSampleTimingInfo
    ) -> CMSampleBuffer? {



        var timing = timing

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let size = CGSize(width: width, height: height)


        // 只有在第一次或解析度改變時才重新建立
        if cachedFormatDescription == nil || cachedFormatSize != size {
            var formatDesc: CMFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDesc
            ) == noErr,
          
            let fmt = formatDesc else {
                 return nil
            }

            cachedFormatDescription = fmt
            cachedFormatSize = size
         }

        guard let fmt = cachedFormatDescription else { return nil }
             

        // 3️⃣ 建立新的 sampleBuffer
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





