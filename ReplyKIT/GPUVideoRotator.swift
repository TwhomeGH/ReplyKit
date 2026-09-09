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

    var isPermanentlyDead: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return metalPermanentFailure
    }

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

    /// Params 幾何快照的 key：Params 只依「輸入尺寸 / 輸出尺寸 / oDst / 角度」
    /// 而定，對同一解析度與角度是常數。frame 每幀只比對 key，命中就重用
    /// 已算好的 Params，不再重算 scale/offset/rot matrix。
    struct RenderParamsKey: Equatable {
        let srcW: UInt32
        let srcH: UInt32
        let dstW: UInt32
        let dstH: UInt32
        let oDstW: UInt32
        let oDstH: UInt32
        let angleRaw: UInt32
    }

    /// Params 快照（geometry snapshot）：由 frame preamble 執行緒在 rotateAsync 內
    /// 計算/更新；多幀 preamble 併行，因此以 lifecycleLock 保護 key 與值。
    private var renderParamsKey: RenderParamsKey?
    private var renderParamsValue: Params?

    /// 純函式：依尺寸/角度計算 Params（scale/offset/rot matrix）。
    /// 分離出來以便快照重算與測試；無共享狀態。
    static func makeParams(
        srcW: UInt32, srcH: UInt32,
        dstW: UInt32, dstH: UInt32,
        oDstW: UInt32, oDstH: UInt32,
        angle: RotationAngle
    ) -> Params {
        let rotW: Float, rotH: Float
        if angle.rawValue % 180 == 0 {
            rotW = Float(srcW); rotH = Float(srcH)
        } else {
            rotW = Float(srcH); rotH = Float(srcW)
        }
        let targetW = Float(oDstW > 0 ? oDstW : dstW)
        let targetH = Float(oDstH > 0 ? oDstH : dstH)
        let scaleX = targetW / rotW
        let scaleY = targetH / rotH
        let uniformScale = min(scaleX, scaleY)
        let scaledW = rotW * uniformScale
        let scaledH = rotH * uniformScale
        let offsetX = (targetW - scaledW) * 0.5
        let offsetY = (targetH - scaledH) * 0.5

        let (r00, r01, r10, r11): (Float, Float, Float, Float)
        switch angle {
        case .portrait:          r00 = 1; r01 = 0; r10 = 0; r11 = 1
        case .landscapeRight:    r00 = 0; r01 = 1; r10 = -1; r11 = 0
        case .portraitUpsideDown: r00 = -1; r01 = 0; r10 = 0; r11 = -1
        case .landscapeLeft:     r00 = 0; r01 = -1; r10 = 1; r11 = 0
        }

        return Params(
            srcWidth: srcW, srcHeight: srcH,
            dstWidth: dstW, dstHeight: dstH,
            oDstW: oDstW, oDstH: oDstH,
            rot00: r00, rot01: r01, rot10: r10, rot11: r11,
            rotCenterX: rotW * 0.5, rotCenterY: rotH * 0.5,
            srcCenterX: Float(srcW) * 0.5, srcCenterY: Float(srcH) * 0.5,
            halfW: Float(srcW) * 0.5, halfH: Float(srcH) * 0.5,
            uniformScale: uniformScale,
            offsetX: offsetX, offsetY: offsetY
        )
    }


    struct OutputKey: Hashable {
        let width: Int
        let height: Int
    }

    private var outputPool: [OutputKey: CVPixelBufferPool] = [:]
    private let outputPoolLock = NSLock()
    private let maxPoolSize: Int

    // MARK: - Metal Output Pool
    final class ReusableOutputSet {
        let pixelBuffer: CVPixelBuffer
        let yTex: MTLTexture
        let uvTex: MTLTexture
        let formatDescription: CMVideoFormatDescription?
        let cvY: CVMetalTexture?
        let cvUV: CVMetalTexture?

        init(pixelBuffer: CVPixelBuffer, yTex: MTLTexture, uvTex: MTLTexture,
             cvY: CVMetalTexture? = nil, cvUV: CVMetalTexture? = nil) {
            self.pixelBuffer = pixelBuffer
            self.yTex = yTex
            self.uvTex = uvTex
            self.cvY = cvY
            self.cvUV = cvUV

            // formatDescription 只依 pixelBuffer 的格式/尺寸而定，同一 pool key 的所有 buffer
            // 共用相同值；在建立時就生成並以 immutable let 持有，避免 completion thread
            // 併發寫入共享 cachedFormatDescription 的 data race。
            var fd: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &fd
            )
            self.formatDescription = (status == noErr) ? fd : nil
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

    func cleanup() {
        // isActive 只在 outputPoolLock 領域讀寫（cleanup 為唯一寫入者，
        // outputBufferPool 在該鎖內讀取）。
        outputPoolLock.lock()
        guard isActive else {
            outputPoolLock.unlock()
            return
        }
        isActive = false
        outputPoolLock.unlock()
        cleanupResources()
    }


    // MARK: - Cleanup
    /// 需在 lifecycleLock 未被持有的 context 呼叫（self-lock）。
    private func cleanupResources() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        cleanupResourcesLocked()
    }

    /// 假設呼叫者已持有 lifecycleLock。
    private func cleanupResourcesLocked() {
        hasMetalResources = false

        outputPoolLock.lock()
        let retiredPools = outputPool
        let poolCount = retiredPools.count
        outputPool.removeAll()
        outputPoolLock.unlock()

        pipelineBilinear = nil
        pipelineBicubic = nil

        for pool in retiredPools.values {
            CVPixelBufferPoolFlush(pool, .excessBuffers)
        }
        logTo("cleanup called - releasing \(poolCount) output pool(s)")
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
    private let commandStatsLock = NSLock()
    private var nextCommandID: UInt64 = 0
    private var submittedCommandCount: UInt64 = 0
    private var completedCommandCount: UInt64 = 0
    private var timedOutCommandCount: UInt64 = 0
    private var commandBufferInFlight = 0

    // GPU completion latency 統計（fixed-capacity circular buffer）。只在
    // commandStatsLock 內讀寫。completion handler 每次成功記錄一筆 submit→down
    // 延遲（覆寫最舊）；診斷快照（5s 一次）取出排序算 avg/max/p95，不影響熱路徑。
    private let latencyRingCapacity = 600
    private var latencyRing = [Double](repeating: 0, count: 600)
    private var latencyRingCount = 0
    private var latencyRingWrite = 0
    /// 限制 in-flight command buffer 數量，防止 GPU 被淹沒
    private var originalQualityMode: QualityMode?

    /// 保護「qualityMode / originalQualityMode / metalPermanentFailure /
    /// consecutiveMetalFailures / pipeline 生命週期」等跨執行緒狀態。
    ///
    /// 寫入方: handleMetalFailure (GPU completion / timeout queue)、
    ///         cleanup() (FrameProcessorActor)。
    /// 讀取方: ensureMetalPipelineSnapshot()、isPermanentlyDead、
    ///         completion handler 的成功 reset。
    /// frame 的熱路徑只透過 ensureMetalPipelineSnapshot() 在每幀 preamble 取
    /// 一次 snapshot，之後 renderPlaneYUV 用傳進來的 local pipeline，不再回頭
    /// 讀共享 var——因此每幀只多一次短鎖，卻消除整組 data race。
    private let lifecycleLock = NSLock()

    private var effectiveQualityMode: QualityMode {
        if let original = originalQualityMode { return original }
        return qualityMode
    }

    /// 偵測 Metal 操作失敗，自動 cleanup 讓下一幀重新初始化。
    /// 只會在失敗路徑（completion handler / timeout / preamble 建立失敗）被呼叫，
    /// 不在逐幀熱路徑上，因此整個 body 在 lifecycleLock 內執行是安全的。
    private func handleMetalFailure(_ reason: String) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        handleMetalFailureLocked(reason)
    }

    /// 成功 completion handler 呼叫；與 handleMetalFailure 的累加互斥。
    private func resetConsecutiveFailures() {
        lifecycleLock.lock()
        if consecutiveMetalFailures != 0 {
            consecutiveMetalFailures = 0
        }
        lifecycleLock.unlock()
    }

    /// 假設呼叫者已持有 lifecycleLock。
    private func handleMetalFailureLocked(_ reason: String) {
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
            cleanupResourcesLocked()
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

    private func markCommandCompleted(elapsedMs: Double) -> (inFlight: Int, completed: UInt64) {
        commandStatsLock.lock()
        completedCommandCount &+= 1
        commandBufferInFlight = max(0, commandBufferInFlight - 1)
        // 記錄 completion latency（覆寫最舊樣本）
        latencyRing[latencyRingWrite] = elapsedMs
        latencyRingWrite = (latencyRingWrite + 1) % latencyRingCapacity
        if latencyRingCount < latencyRingCapacity {
            latencyRingCount += 1
        }
        let snapshot = (commandBufferInFlight, completedCommandCount)
        commandStatsLock.unlock()
        return snapshot
    }

    /// completion latency 彙總（avg/max/p95 ms）。僅診斷取樣時呼叫。
    private func latencyStats() -> (avgMs: Double, maxMs: Double, p95Ms: Double) {
        commandStatsLock.lock()
        let count = latencyRingCount
        guard count > 0 else {
            commandStatsLock.unlock()
            return (0, 0, 0)
        }
        // 依寫入順序展開成時間序
        var samples = [Double](repeating: 0, count: count)
        var idx = 0
        for i in 0..<count {
            let ringIndex = (latencyRingWrite - count + i + latencyRingCapacity) % latencyRingCapacity
            samples[idx] = latencyRing[ringIndex]
            idx += 1
        }
        commandStatsLock.unlock()

        let sorted = samples.sorted()
        let avg = sorted.reduce(0, +) / Double(sorted.count)
        let maxMs = sorted.last ?? 0
        let p95Index = Int((Double(sorted.count) * 0.95).rounded(.up)) - 1
        let p95 = sorted[max(0, min(sorted.count - 1, p95Index))]
        return (avg, maxMs, p95)
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

    /// completion latency 彙總（診斷用）。空樣本時回傳 0。
    func completionLatencyStats() -> (avgMs: Double, maxMs: Double, p95Ms: Double) {
        latencyStats()
    }

    private func poolSnapshot() -> String {
        outputPoolLock.lock()
        let text = outputPool
            .map { "\($0.key.width)x\($0.key.height)" }
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

    /// frame preamble 的單一快照點：在 lifecycleLock 內檢查永久死亡、惰性建立
    /// 目前模式所需的 pipeline、並解析出「這一幀要用的 compute pipeline」。
    /// renderPlaneYUV 不再回頭讀 effectiveQualityMode / pipelineBilinear /
    /// pipelineBicubic 等共享 var，因此消除 qualityMode 降級（completion 執行緒
    /// 寫入）與 frame 讀取之間的 data race。
    /// - Returns: 本幀可用的 compute pipeline；nil 表示永久死亡或建立失敗。
    private func ensureMetalPipelineSnapshot() -> MTLComputePipelineState? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard !metalPermanentFailure else {
            logTo("Metal 已永久死亡，跳過 GPU 初始化")
            return nil
        }
        guard !hasMetalResources else {
            return resolvePipelineLocked()
        }

        // 只編譯目前選擇的管線（.live = bilinear，.quality = bicubic）
        switch qualityMode {
        case .live where pipelineBilinear == nil:
            guard buildComputePipeline(functionName: "rotateNV12_bilinear", store: &pipelineBilinear) else {
                handleMetalFailureLocked("建立 Bilinear ComputePipeline 失敗")
                return nil
            }
        case .quality where pipelineBicubic == nil:
            guard buildComputePipeline(functionName: "rotateNV12_bicubic", store: &pipelineBicubic) else {
                handleMetalFailureLocked("建立 Bicubic ComputePipeline 失敗")
                return nil
            }
        default:
            break
        }

        hasMetalResources = true
        prewarmPool()
        return resolvePipelineLocked()
    }

    /// 假設呼叫者已持有 lifecycleLock。
    private func resolvePipelineLocked() -> MTLComputePipelineState? {
        effectiveQualityMode == .live ? pipelineBilinear : pipelineBicubic
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

         // 延遲初始化 Metal/TextureCache，並解析本幀 compute pipeline（單一快照點）
        guard let computePipeline = ensureMetalPipelineSnapshot() else {
            return nil
        }

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
            // Pool pressure is backpressure, not a Metal device failure.
            return nil
        }

        let yTexture = makeTexture(from: inBuffer, planeIndex: 0)
        let uvTexture = makeTexture(from: inBuffer, planeIndex: 1)
        let commandBuffer = MetalContext.shared.queue.makeCommandBuffer()

        guard let ycvTexIn = yTexture,
            let uvcvTexIn = uvTexture,
            let cmd = commandBuffer else {


            handleMetalFailure("makeTexture 或 makeCommandBuffer 失敗 src:\(srcW)x\(srcH) dst:\(dstW)x\(dstH) y:\(yTexture != nil) uv:\(uvTexture != nil) cmd:\(commandBuffer != nil) fmt:\(pixelFormatDescription(inBuffer)) planes:\(CVPixelBufferGetPlaneCount(inBuffer))")
            

            return nil
        }

        let commandSnapshot = nextCommandSnapshot()
        cmd.label = "ReplyKit.video.rotate#\(commandSnapshot.id) \(srcW)x\(srcH)->\(dstW)x\(dstH)"

        guard renderPlaneYUV(cmd: cmd, compute: computePipeline,
                        srcY: ycvTexIn.tex, srcUV: uvcvTexIn.tex,
                        dstY: outSet.yTex, dstUV: outSet.uvTex, angle: angle) else {
            _ = markCommandCompleted(elapsedMs: 0)
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
                let completedStats = self.markCommandCompleted(elapsedMs: elapsedMs)


                frameC.inY = nil
                frameC.inUV = nil

                let isCompleted = cmd.status == .completed && cmd.error == nil
                let wrapped = isCompleted
                    ? self.wrapPixelBuffer(frameC.outSet, timing: frameC.timing)
                    : nil

                if isCompleted, let wrapped {
                    self.resetConsecutiveFailures()

                    self.tsDebugger.log(
                        originalTime: frameC.timing,
                        wrapped: wrapped
                    )
                } else if !completion.completedAfterTimeout {
                    self.handleMetalFailure("commandBuffer 完成失敗 cmd:#\(commandSnapshot.id) status:\(cmd.status.rawValue) elapsed:\(String(format: "%.2f", elapsedMs))ms error:\(self.describeCommandBufferError(cmd.error))")
                } else {
                    self.logTo("commandBuffer 延遲完成 cmd:#\(commandSnapshot.id) status:\(cmd.status.rawValue) elapsed:\(String(format: "%.2f", elapsedMs))ms inflight:\(completedStats.inFlight)")
                }

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
private func outputBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        let key = OutputKey(width: width, height: height)
        outputPoolLock.lock()
        let active = isActive
        let existing = outputPool[key]
        outputPoolLock.unlock()
        guard active else { return nil }
        if let existing { return existing }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created) == kCVReturnSuccess,
              let created else { return nil }

        outputPoolLock.lock()
        defer { outputPoolLock.unlock() }
        guard isActive else { return nil }
        if let existing = outputPool[key] { return existing }
        outputPool[key] = created
        return created
    }

    private func getReusableOutput(width: Int, height: Int) -> ReusableOutputSet? {
        guard let pool = outputBufferPool(width: width, height: height) else { return nil }
        let auxiliary = [
            kCVPixelBufferPoolAllocationThresholdKey as String: max(3, maxPoolSize)
        ] as CFDictionary
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, auxiliary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }
        guard let y = makeTexture(from: buffer, planeIndex: 0),
              let uv = makeTexture(from: buffer, planeIndex: 1) else { return nil }
        // Core Video may reuse storage only after all consumers release the buffer.
        return ReusableOutputSet(pixelBuffer: buffer, yTex: y.tex, uvTex: uv.tex,
                                 cvY: y.cv, cvUV: uv.cv)
    }

    private func prewarmPool() {
        guard hasMetalResources else { return }
        for (width, height) in [(dstWW, dstHH), (OutWW, OutHH)] where width > 0 && height > 0 {
            var buffers: [ReusableOutputSet] = []
            for _ in 0..<3 {
                if let buffer = getReusableOutput(width: width, height: height) {
                    buffers.append(buffer)
                }
            }
            withExtendedLifetime(buffers) {}
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
    /// formatDescription 來自 outSet 建立時就固定的 immutable let，因此 completion thread
    /// 併發呼叫時不再讀寫共享 mutable cache（cachedFormatDescription/cachedFormatSize），
    /// 消除既有 data race。
    /// - Parameters:
    ///   - outSet: pooled output set（內建自己的 formatDescription）
    ///   - timing: The timing information for the sample buffer.
    /// - Returns: A CMSampleBuffer containing the pixel buffer and timing, or nil on failure.
   private func wrapPixelBuffer(
    _ outSet: ReusableOutputSet,
    timing: CMSampleTimingInfo
) -> CMSampleBuffer? {

    let pixelBuffer = outSet.pixelBuffer

    // formatDescription 在 pool 建立時就生成；理論上一定存在，這裡做雙重保險
    let fmt: CMVideoFormatDescription?
    if let cached = outSet.formatDescription {
        fmt = cached
    } else {
        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        if status == noErr, let created = formatDesc {
            fmt = created
        } else {
            sendlog(message: "CMVideoFormatDescriptionCreateForImageBuffer failed: \(status)")
            return fallbackSampleBuffer(pixelBuffer: pixelBuffer, timing: timing)
        }
    }

    guard let validFmt = fmt else {
        sendlog(message: "No valid formatDescription available")
        return fallbackSampleBuffer(pixelBuffer: pixelBuffer, timing: timing)
    }

    var sampleBuffer: CMSampleBuffer?
    var timingInfo = timing

    let status = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: validFmt,
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
                        compute: MTLComputePipelineState,
                        srcY: MTLTexture, srcUV: MTLTexture,
                        dstY: MTLTexture, dstUV: MTLTexture,
                        angle: RotationAngle) -> Bool {

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

        // Params 幾何快照：只依 src/dst/oDst/angle 而定；同一解析度與角度下
        // 每幀直接重用已算好的 Params，不再重算 scale/offset/rot matrix。
        var params = paramsForFrame(
            srcW: UInt32(srcY.width), srcH: UInt32(srcY.height),
            dstW: UInt32(dstY.width), dstH: UInt32(dstY.height),
            angle: angle
        )

        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)

        if OutWW > 0 && OutHH > 0 {
            if debug { logTo("GPU Shader 寬高 參數:\(OutWW)x\(OutHH)") }
            encoder.dispatchThreads(MTLSize(width: OutWW, height: OutHH, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: tgWidth, height: tgHeight, depth: 1))

        } else {
            if debug { logTo("GPU Shader 寬高參數使用輸入尺寸:\(srcY.width)x\(srcY.height)") }
            encoder.dispatchThreads(MTLSize(width: dstY.width, height: dstY.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: tgWidth, height: tgHeight, depth: 1))

        }

        encoder.endEncoding()
        OutputOverlayMetalRenderer.shared.applyIfNeeded(commandBuffer: cmd, dstY: dstY, dstUV: dstUV)
        return true
    }

    /// Params 幾何快照查詢/更新。lifecycleLock 保護快照 key 與值（多幀 preamble
    /// 併行時只做一次幾何計算，其餘幀命中快照）。
    private func paramsForFrame(
        srcW: UInt32, srcH: UInt32,
        dstW: UInt32, dstH: UInt32,
        angle: RotationAngle
    ) -> Params {
        let oDstW = UInt32(OutWW)
        let oDstH = UInt32(OutHH)
        let key = RenderParamsKey(
            srcW: srcW, srcH: srcH,
            dstW: dstW, dstH: dstH,
            oDstW: oDstW, oDstH: oDstH,
            angleRaw: angle.rawValue
        )

        lifecycleLock.lock()
        if let cachedKey = renderParamsKey, cachedKey == key,
           let cached = renderParamsValue {
            lifecycleLock.unlock()
            return cached
        }
        let params = Self.makeParams(
            srcW: srcW, srcH: srcH,
            dstW: dstW, dstH: dstH,
            oDstW: oDstW, oDstH: oDstH,
            angle: angle
        )
        renderParamsKey = key
        renderParamsValue = params
        lifecycleLock.unlock()
        return params
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

