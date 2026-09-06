@preconcurrency import Metal
import VideoToolbox
import CoreVideo
import CoreMedia
import simd

import Foundation
import AVFoundation
import Accelerate
import QuartzCore
import MachO

import HaishinKit

struct GPUCommandStats: Sendable {
    let submitted: UInt64
    let completed: UInt64
    let timedOut: UInt64
    let inFlight: Int

    static let empty = GPUCommandStats(submitted: 0, completed: 0, timedOut: 0, inFlight: 0)

    var summary: String {
        "submitted:\(submitted) completed:\(completed) timeout:\(timedOut) inflight:\(inFlight)"
    }
}



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

    private var isActive = true

    var isPermanentlyDead: Bool { metalPermanentFailure }

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
        var oDstW: UInt32
        var oDstH: UInt32
        var rot00: Float
        var rot01: Float
        var rot10: Float
        var rot11: Float
        var rotCenterX: Float
        var rotCenterY: Float
        var srcCenterX: Float
        var srcCenterY: Float
        var halfW: Float
        var halfH: Float
        var uniformScale: Float
        var offsetX: Float
        var offsetY: Float
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

    func cleanup() async {
        guard isActive else { return }
        isActive = false
        cleanupResources()
    }


    // MARK: - Cleanup
    private func cleanupResources() {
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


        let sizeStr = (dstWW > 0 && dstHH > 0) ? "\(dstWW)x\(dstHH)" : "auto(來源解析度)"
        sendlog(
            message:"GPU Rotator init:\(sizeStr) Debug:\(debug) 使用:\(qualityMode) PoolSize:\(maxPoolSize)",
            flush: true
        )

        // 預先分配 output buffer pool（init 時就建好，避免 runtime 分配失敗）
        prewarmPool()

    }

    var hasMetalResources = false

    /// 連續 Metal 操作失敗計數，達到閾值時自動重建管線
    private var consecutiveMetalFailures = 0
    private let maxConsecutiveMetalFailures = 5
    /// 達到上限後標記 GPU 永久死亡，不再重試 GPU
    private var metalPermanentFailure = false
    private let commandBufferTimeout: TimeInterval = 1.0
    private let metalFailureLogLock = NSLock()
    private var lastMetalFailureLogAt = Date.distantPast
    private var lastPoolPressureLogAt = Date.distantPast
    private let commandStatsLock = NSLock()
    private var nextCommandID: UInt64 = 0
    private var submittedCommandCount: UInt64 = 0
    private var completedCommandCount: UInt64 = 0
    private var timedOutCommandCount: UInt64 = 0
    private var commandBufferInFlight = 0
    /// 限制 in-flight command buffer 數量，防止 GPU 被淹沒
    private var originalQualityMode: QualityMode?
    private var effectiveQualityMode: QualityMode {
        if let original = originalQualityMode { return original }
        return qualityMode
    }

    /// 偵測 Metal 操作失敗，自動 cleanup 讓下一幀重新初始化
    private func handleMetalFailure(_ reason: String) {
        guard !metalPermanentFailure else { return }
        consecutiveMetalFailures += 1
        let failureCount = consecutiveMetalFailures
        logMetalFailure(reason: reason, count: failureCount)
        // 自動降品質：首次失敗時切到 bilinear
        if failureCount == 1 && originalQualityMode == nil && qualityMode == .quality {
            originalQualityMode = .quality
            logTo("Metal 失敗，自動降品質 quality → live (bilinear)")
        }
        if consecutiveMetalFailures >= maxConsecutiveMetalFailures {
            sendlog(message: "[GPU Rotator] Metal 連續失敗 \(failureCount) 次，重建管線與 command queue")
            cleanupResources()
            MetalContext.shared.rebuildQueue()
            consecutiveMetalFailures = 0
            metalPermanentFailure = true
            logTo("Metal 連續失敗達上限，標記永久死亡，後續直接走 CPU fallback")
            // 恢復原始品質模式
            if let original = originalQualityMode {
                qualityMode = original
                originalQualityMode = nil
                logTo("Metal 恢復，品質還原 quality")
            }
        }
    }

    private func logMetalFailure(reason: String, count: Int) {
        let now = Date()
        var shouldLog = count == 1 || count >= maxConsecutiveMetalFailures

        metalFailureLogLock.lock()
        if now.timeIntervalSince(lastMetalFailureLogAt) >= 2.0 {
            shouldLog = true
        }
        if shouldLog {
            lastMetalFailureLogAt = now
        }
        metalFailureLogLock.unlock()

        guard shouldLog else { return }
        sendlog(message: "[GPU Rotator] Metal 失敗[\(count)/\(maxConsecutiveMetalFailures)]: \(reason) stats:\(commandStatsSnapshot()) pools:\(poolSnapshot()) mem:\(memorySnapshot())")
    }

    private func nextCommandSnapshot() -> (id: UInt64, inFlight: Int, submitted: UInt64) {
        commandStatsLock.lock()
        nextCommandID &+= 1
        submittedCommandCount &+= 1
        commandBufferInFlight += 1
        let snapshot = (nextCommandID, commandBufferInFlight, submittedCommandCount)
        commandStatsLock.unlock()
        return snapshot
    }

    private func markCommandCompleted() -> (inFlight: Int, completed: UInt64) {
        commandStatsLock.lock()
        completedCommandCount &+= 1
        commandBufferInFlight = max(0, commandBufferInFlight - 1)
        let snapshot = (commandBufferInFlight, completedCommandCount)
        commandStatsLock.unlock()
        return snapshot
    }

    private func markCommandTimedOut() -> UInt64 {
        commandStatsLock.lock()
        timedOutCommandCount &+= 1
        let count = timedOutCommandCount
        commandStatsLock.unlock()
        return count
    }

    private func commandStatsSnapshot() -> String {
        commandStats().summary
    }

    func commandStats() -> GPUCommandStats {
        commandStatsLock.lock()
        let stats = GPUCommandStats(
            submitted: submittedCommandCount,
            completed: completedCommandCount,
            timedOut: timedOutCommandCount,
            inFlight: commandBufferInFlight
        )
        commandStatsLock.unlock()
        return stats
    }

    private func poolSnapshot() -> String {
        outputPoolLock.lock()
        let text = outputPool
            .map { "\($0.key.width)x\($0.key.height):\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        outputPoolLock.unlock()
        return text.isEmpty ? "empty" : text
    }

    private func memorySnapshot() -> String {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return "resident:unknown status:\(result)"
        }
        return "resident:\(info.resident_size / 1024 / 1024)MB"
    }

    private func describeCommandBufferError(_ error: Error?) -> String {
        guard let error else { return "nil" }
        let ns = error as NSError
        var parts = ["domain:\(ns.domain)", "code:\(ns.code)", "desc:\(ns.localizedDescription)"]
        let mtlName: String
        switch ns.code {
        case 0: mtlName = "none"
        case 1: mtlName = "internal"
        case 2: mtlName = "timeout"
        case 3: mtlName = "pageFault"
        case 4: mtlName = "blacklisted"
        case 7: mtlName = "notPermitted"
        case 8: mtlName = "outOfMemory"
        case 9: mtlName = "invalidResource"
        case 10: mtlName = "memoryless"
        case 11: mtlName = "deviceRemoved"
        case 12: mtlName = "stackOverflow"
        default: mtlName = "unknown(\(ns.code))"
        }
        parts.append("mtl:\(mtlName)")
        if let encoderInfos = ns.userInfo[MTLCommandBufferEncoderInfoErrorKey] as? [MTLCommandBufferEncoderInfo], !encoderInfos.isEmpty {
            let encoderText = encoderInfos.enumerated().map { index, info in
                "#\(index) label:\(info.label) status:\(info.errorState.rawValue)"
            }.joined(separator: ";")
            parts.append("encoders:\(encoderText)")
        }
        if !ns.userInfo.isEmpty {
            parts.append("userInfo:\(ns.userInfo.keys.map { "\($0)" }.sorted().joined(separator: ","))")
        }
        return parts.joined(separator: " ")
    }

    private func ensureMetalResources() -> Bool {
        guard !metalPermanentFailure else {
            logTo("Metal 已永久死亡，跳過 GPU 初始化")
            return false
        }
        guard hasMetalResources == false else {
            return true
        }

        // 只編譯目前選擇的管線（.live = bilinear，.quality = bicubic）
        switch qualityMode {
        case .live where pipelineBilinear == nil:
            guard buildComputePipeline(functionName: "rotateNV12_bilinear", store: &pipelineBilinear) else {
                handleMetalFailure("建立 Bilinear ComputePipeline 失敗")
                return false
            }
        case .quality where pipelineBicubic == nil:
            guard buildComputePipeline(functionName: "rotateNV12_bicubic", store: &pipelineBicubic) else {
                handleMetalFailure("建立 Bicubic ComputePipeline 失敗")
                return false
            }
        default:
            break
        }

        hasMetalResources = true
        prewarmPool()
        return true

    }

    private func buildComputePipeline(functionName: String, store: inout MTLComputePipelineState?) -> Bool {
        do {
            guard let fn = MetalContext.shared.library.makeFunction(name: functionName) else {
                logTo("buildComputePipeline: function \(functionName) not found in library")
                return false
            }
            store = try MetalContext.shared.device.makeComputePipelineState(function: fn)
            return true
        } catch {
            logTo("buildComputePipeline(\(functionName)) 失敗: \(error.localizedDescription)")
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

    private final class CommandCompletionState: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false
        private var timedOut = false

        func markCompletion() -> (shouldResume: Bool, completedAfterTimeout: Bool) {
            lock.lock()
            defer { lock.unlock() }

            let completedAfterTimeout = timedOut
            guard !didResume else {
                return (false, completedAfterTimeout)
            }

            didResume = true
            return (true, completedAfterTimeout)
        }

        func markTimeout() -> Bool {
            lock.lock()
            defer { lock.unlock() }

            guard !didResume else { return false }
            didResume = true
            timedOut = true
            return true
        }
    }




    // MARK: - Enqueue Frame
    func rotateAsync(pixelBuffer: CVPixelBuffer, originalTime: CMSampleTimingInfo, angle: RotationAngle) async -> CMSampleBuffer? {

         // 延遲初始化 Metal/TextureCache
        guard ensureMetalResources() else {
            return nil
        }

        timing = originalTime

        let inBuffer = pixelBuffer
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
        guard let outSet = getReusableOutput(width: dstW, height: dstH) else {
            handleMetalFailure("getReusableOutput(\(dstW)x\(dstH)) 返回 nil")
            return nil
        }

        let yTexture = makeTexture(from: inBuffer, planeIndex: 0)
        let uvTexture = makeTexture(from: inBuffer, planeIndex: 1)
        let commandBuffer = MetalContext.shared.queue.makeCommandBuffer()

        guard let ycvTexIn = yTexture,
            let uvcvTexIn = uvTexture,
            let cmd = commandBuffer else {

            recycleOutput(outSet)

            handleMetalFailure("makeTexture 或 makeCommandBuffer 失敗 src:\(srcW)x\(srcH) dst:\(dstW)x\(dstH) y:\(yTexture != nil) uv:\(uvTexture != nil) cmd:\(commandBuffer != nil) fmt:\(pixelFormatDescription(inBuffer)) planes:\(CVPixelBufferGetPlaneCount(inBuffer))")
            

            return nil
        }

        let commandSnapshot = nextCommandSnapshot()
        cmd.label = "ReplyKit.video.rotate#\(commandSnapshot.id) \(srcW)x\(srcH)->\(dstW)x\(dstH)"

        guard renderPlaneYUV(cmd: cmd, srcY: ycvTexIn.tex, srcUV: uvcvTexIn.tex,
                        dstY: outSet.yTex, dstUV: outSet.uvTex, angle: angle) else {
            recycleOutput(outSet)
            _ = markCommandCompleted()
            handleMetalFailure("renderPlaneYUV 建立 encoder 失敗 cmd:#\(commandSnapshot.id) srcY:\(textureDescription(ycvTexIn.tex)) srcUV:\(textureDescription(uvcvTexIn.tex)) dstY:\(textureDescription(outSet.yTex)) dstUV:\(textureDescription(outSet.uvTex))")
            return nil
        }


        // 防止 GPU command buffer 永久不回 completion，讓外層 actor 可以被 watchdog 重建。
        return await withCheckedContinuation { (cont: CheckedContinuation<CMSampleBuffer?, Never>) in

            let completionState = CommandCompletionState()
            

            let frameC = FrameContext(timing: originalTime, outSet: outSet,
                                        inY: ycvTexIn.cv, inUV: uvcvTexIn.cv
            )

            let submittedAt = CACurrentMediaTime()

            cmd.addCompletedHandler { [self] _ in
                let completion = completionState.markCompletion()
                let elapsedMs = (CACurrentMediaTime() - submittedAt) * 1000
                let completedStats = self.markCommandCompleted()


                frameC.inY = nil
                frameC.inUV = nil

                let isCompleted = cmd.status == .completed && cmd.error == nil
                let wrapped = isCompleted
                    ? self.wrapPixelBuffer(frameC.outPB, timing: frameC.timing)
                    : nil

                if isCompleted, let wrapped {
                    self.consecutiveMetalFailures = 0

                    self.tsDebugger.log(
                        originalTime: frameC.timing,
                        wrapped: wrapped
                    )
                } else if !completion.completedAfterTimeout {
                    self.handleMetalFailure("commandBuffer 完成失敗 cmd:#\(commandSnapshot.id) status:\(cmd.status.rawValue) elapsed:\(String(format: "%.2f", elapsedMs))ms error:\(self.describeCommandBufferError(cmd.error))")
                } else {
                    self.logTo("commandBuffer 延遲完成 cmd:#\(commandSnapshot.id) status:\(cmd.status.rawValue) elapsed:\(String(format: "%.2f", elapsedMs))ms inflight:\(completedStats.inFlight)")
                }

                self.recycleOutput(frameC.outSet)
                if completion.shouldResume {
                    cont.resume(returning: wrapped)
                }
                self.logTo("GPU Frame down cmd:#\(commandSnapshot.id) pts:\(frameC.timing.presentationTimeStamp)s elapsed:\(String(format: "%.2f", elapsedMs))ms inflight:\(completedStats.inFlight)")
            }

            cmd.commit()
            self.logTo("GPU command submit cmd:#\(commandSnapshot.id) inflight:\(commandSnapshot.inFlight) submitted:\(commandSnapshot.submitted)")

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + commandBufferTimeout) { [self] in
                guard completionState.markTimeout() else { return }

                let timeoutCount = self.markCommandTimedOut()
                self.handleMetalFailure("commandBuffer 逾時 cmd:#\(commandSnapshot.id) timeout:\(String(format: "%.1f", commandBufferTimeout))s totalTimeout:\(timeoutCount) status:\(cmd.status.rawValue) error:\(self.describeCommandBufferError(cmd.error)) src:\(srcW)x\(srcH) dst:\(dstW)x\(dstH)")
                cont.resume(returning: nil)
            }
        }
    }


    

  // MARK: - Reusable Output
private func getReusableOutput(width: Int, height: Int) -> ReusableOutputSet? {
    guard isActive else { return nil }
    outputPoolLock.lock()

    let key = OutputKey(width: width, height: height)
    if var pool = outputPool[key], !pool.isEmpty {
        let set = pool.removeFirst()
        outputPool[key] = pool
        outputPoolLock.unlock()
        return set
    }
    let currentPools = outputPool
        .map { "\($0.key.width)x\($0.key.height):\($0.value.count)" }
        .sorted()
        .joined(separator: ",")
    outputPoolLock.unlock()

    let now = Date()
    if now.timeIntervalSince(lastPoolPressureLogAt) >= 5.0 {
        lastPoolPressureLogAt = now
        logTo("output pool miss \(width)x\(height)，runtime 建立新 buffer，目前 pools:\(currentPools.isEmpty ? "empty" : currentPools)")
    }

    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVMetalTextureUsage as String: NSNumber(value: MTLTextureUsage.shaderWrite.rawValue),
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
    ]
    let status = CVPixelBufferCreate(nil, width, height,
                                     kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                     attrs as CFDictionary, &pb)
    guard status == kCVReturnSuccess, let pixelBuffer = pb else {
        sendlog(message: "[GPU Rotator] CVPixelBufferCreate 失敗 status:\(status) size:\(width)x\(height) stats:\(commandStatsSnapshot()) pools:\(poolSnapshot()) mem:\(memorySnapshot())")
        return nil
    }

    let yTex = makeTexture(from: pixelBuffer, planeIndex: 0)
    let uvTex = makeTexture(from: pixelBuffer, planeIndex: 1)
    guard let yTex,
          let uvTex else {
        sendlog(message: "[GPU Rotator] output texture 建立失敗 size:\(width)x\(height) y:\(yTex != nil) uv:\(uvTex != nil) fmt:\(pixelFormatDescription(pixelBuffer))")
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

    // MARK: - Pre-warm pool
    private func prewarmPool() {
        guard hasMetalResources else { return }
        let sizes: [(Int, Int)] = [(dstWW, dstHH), (OutWW, OutHH)]
        for (w, h) in sizes where w > 0 && h > 0 {
            let key = OutputKey(width: w, height: h)
            outputPoolLock.lock()
            let alreadyExists = outputPool[key] != nil
            outputPoolLock.unlock()
            guard !alreadyExists else { continue }
            var pool: [ReusableOutputSet] = []
            for _ in 0..<3 {
                if let set = getReusableOutput(width: w, height: h) {
                    pool.append(set)
                }
            }
            if !pool.isEmpty {
                outputPoolLock.lock()
                outputPool[key] = pool
                outputPoolLock.unlock()
                logTo("prewarm pool \(w)x\(h): \(pool.count) buffers")
            }
        }
    }

    func makeTexture(from pixelBuffer: CVPixelBuffer, planeIndex: Int) -> (cv: CVMetalTexture, tex: MTLTexture)? {
        guard let cache = MetalContext.shared.ensureTextureCache() else {
            sendlog(message: "[GPU Rotator] makeTexture 失敗: textureCache nil plane:\(planeIndex) fmt:\(pixelFormatDescription(pixelBuffer))")
            return nil
        }
        guard planeIndex < CVPixelBufferGetPlaneCount(pixelBuffer) else {
            sendlog(message: "[GPU Rotator] makeTexture 失敗: plane 越界 plane:\(planeIndex) planes:\(CVPixelBufferGetPlaneCount(pixelBuffer)) fmt:\(pixelFormatDescription(pixelBuffer))")
            return nil
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        let pixelFormat: MTLPixelFormat = (planeIndex == 0) ? .r8Unorm : .rg8Unorm

        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil,
                                                                pixelFormat, width, height, planeIndex, &cvTex)
        guard status == kCVReturnSuccess, let cv = cvTex, let tex = CVMetalTextureGetTexture(cv) else {
            sendlog(message: "[GPU Rotator] makeTexture 失敗 status:\(status) plane:\(planeIndex) planeSize:\(width)x\(height) mtlFmt:\(pixelFormat.rawValue) pbFmt:\(pixelFormatDescription(pixelBuffer))")
            return nil
        }

        return (cv: cv, tex: tex)
    }

    private func pixelFormatDescription(_ pixelBuffer: CVPixelBuffer) -> String {
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        switch fmt {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return "NV12_full"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return "NV12_video"
        case kCVPixelFormatType_32BGRA: return "BGRA"
        case kCVPixelFormatType_32ARGB: return "ARGB"
        default: return String(format: "0x%08x", fmt)
        }
    }

    private func textureDescription(_ texture: MTLTexture) -> String {
        "\(texture.width)x\(texture.height) fmt:\(texture.pixelFormat.rawValue) usage:\(texture.usage.rawValue) storage:\(texture.storageMode.rawValue)"
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
                        angle: RotationAngle) -> Bool {

        guard let compute = (effectiveQualityMode == .live ? pipelineBilinear : pipelineBicubic) else {
            sendlog(message: "[GPU Rotator] renderPlaneYUV 無 compute pipeline mode:\(effectiveQualityMode)")
            return false
        }
        guard let encoder = cmd.makeComputeCommandEncoder() else {
            sendlog(message: "[GPU Rotator] renderPlaneYUV makeComputeCommandEncoder nil cmdStatus:\(cmd.status.rawValue) error:\(describeCommandBufferError(cmd.error))")
            return false
        }
        encoder.label = "ReplyKit.video.rotate.encoder"

        encoder.setComputePipelineState(compute)
        encoder.setTexture(srcY, index: 0)
        encoder.setTexture(srcUV, index: 1)
        encoder.setTexture(dstY, index: 2)
        encoder.setTexture(dstUV, index: 3)

        let tgWidth = compute.threadExecutionWidth
        let tgHeight = compute.maxTotalThreadsPerThreadgroup / tgWidth


        let srcW = UInt32(srcY.width)
        let srcH = UInt32(srcY.height)
        let dstW = UInt32(dstY.width)
        let dstH = UInt32(dstY.height)
        let oDstW_val = UInt32(OutWW)
        let oDstH_val = UInt32(OutHH)

        let rotW: Float, rotH: Float
        if angle.rawValue % 180 == 0 {
            rotW = Float(srcW); rotH = Float(srcH)
        } else {
            rotW = Float(srcH); rotH = Float(srcW)
        }
        let scaleX = Float(oDstW_val > 0 ? oDstW_val : dstW) / Float(rotW)
        let scaleY = Float(oDstH_val > 0 ? oDstH_val : dstH) / Float(rotH)
        let uniformScale = min(scaleX, scaleY)
        let scaledW = rotW * uniformScale
        let scaledH = rotH * uniformScale
        let offsetX = (Float(oDstW_val > 0 ? oDstW_val : dstW) - scaledW) * 0.5
        let offsetY = (Float(oDstH_val > 0 ? oDstH_val : dstH) - scaledH) * 0.5

        let (r00, r01, r10, r11): (Float, Float, Float, Float)
        switch angle {
        case .portrait:          r00 = 1; r01 = 0; r10 = 0; r11 = 1
        case .landscapeRight:    r00 = 0; r01 = 1; r10 = -1; r11 = 0
        case .portraitUpsideDown: r00 = -1; r01 = 0; r10 = 0; r11 = -1
        case .landscapeLeft:     r00 = 0; r01 = -1; r10 = 1; r11 = 0
        }

        var params = Params(
            srcWidth: srcW, srcHeight: srcH,
            dstWidth: dstW, dstHeight: dstH,
            oDstW: oDstW_val, oDstH: oDstH_val,
            rot00: r00, rot01: r01, rot10: r10, rot11: r11,
            rotCenterX: rotW * 0.5, rotCenterY: rotH * 0.5,
            srcCenterX: Float(srcW) * 0.5, srcCenterY: Float(srcH) * 0.5,
            halfW: Float(srcW) * 0.5, halfH: Float(srcH) * 0.5,
            uniformScale: uniformScale,
            offsetX: offsetX, offsetY: offsetY
        )


        

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
        return true
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

