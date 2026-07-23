import HaishinKit
import RTMPHaishinKit
import ReplayKit
import CoreMedia
import os


final class VideoFrameProcessor {
    private actor ProcessorActor {
        private var rotator: RPVideoRotatorNV12BatchQueueOptimized?
        private var lastKey: (useBic: Bool, dstW: Int, dstH: Int, outW: Int, outH: Int, RotateOriginal: Bool)?
        private let sendlog: (String) -> Void
        private var debug: Bool
        private var isProcessing = false

        init(debug: Bool, sendlog: @escaping (String) -> Void) {
            self.debug = debug
            self.sendlog = sendlog
        }

        func processFrame(
            imageBuffer: CVImageBuffer,
            originalTime: CMSampleTimingInfo,
            angle: RotationAngle
        ) async -> CMSampleBuffer? {
            guard !isProcessing else { return nil }
            isProcessing = true
            defer { isProcessing = false }
            guard let rotator = await getOrCreateRotator() else { return nil }
            return await rotator.rotateAsync(
                pixelBuffer: imageBuffer,
                originalTime: originalTime,
                angle: angle
            )
        }

        private func getOrCreateRotator() async -> RPVideoRotatorNV12BatchQueueOptimized? {
            let key = (
                useBic: RPConfig.shared.state.useBic,
                dstW: RPConfig.shared.state.ADWidth,
                dstH: RPConfig.shared.state.ADHeight,
                outW: RPConfig.shared.state.ODWidth,
                outH: RPConfig.shared.state.ODHeight,
                RotateOriginal: RPConfig.shared.state.RotateOriginal
            )
            if let r = rotator, let last = lastKey, last != key {
                await r.cleanup()
                rotator = nil
                sendlog("[Rotator] config changed, recreating")
            }
            lastKey = key

            if let r = rotator { return r }

            let dstRW = RPConfig.shared.state.ADWidth
            let dstRH = RPConfig.shared.state.ADHeight
            let outW = RPConfig.shared.state.ODWidth
            let outH = RPConfig.shared.state.ODHeight
            let mode: RPVideoRotatorNV12BatchQueueOptimized.QualityMode =
                RPConfig.shared.state.useBic ? .quality : .live
            let RotateOriginal = RPConfig.shared.state.RotateOriginal
            guard let r = RPVideoRotatorNV12BatchQueueOptimized(
                dstW: dstRW, dstH: dstRH,
                outW: outW, outH: outH,
                debug: debug,
                useBic: mode,
                RotateOriginal: RotateOriginal
            ) else {
                sendlog("GPU Rotator init failed")
                return nil
            }
            rotator = r
            return r
        }

        func cleanup() async {
            await rotator?.cleanup()
            rotator = nil
        }

        func updateDebug(_ value: Bool) {
            rotator?.debug = value
        }

        func updateTsDebug(_ value: Bool) {
            rotator?.tsDebug(value)
        }

        func updateDestination(width: Int, height: Int) {
            rotator?.dstWW = width
            rotator?.dstHH = height
        }
    }

    private let mediaMixer: MediaMixer
    private let sendlog: (String) -> Void
    private var processorActor: ProcessorActor?

    var angle = RotationAngle(
                rawValue: UInt32(RPConfig.shared.state.Rotate)
            ) ?? .landscapeRight

    var Rotate = RPConfig.shared.state.Rotate

    private func updateRotateFixState() {
        let current = RPConfig.shared.state.Rotate
        guard current != Rotate else { return }
        Rotate = current
        sendlog("🟢 New Rotate \(current)")
    }

    var isActive = true
    var hasPublished = false
    var debug = RPConfig.shared.enableRotateLog
    var processedCount: Int = 0
    var sentCount: Int = 0
    private var isProcessing = false
    private var processingStartedAt: Date?
    private let processingTimeout: TimeInterval = 2.0
    private var watchdogResetCount: Int = 0
    private var consecutiveDropCount: Int = 0
    private let fallbackFreezeThreshold = 3
    private let maxConsecutiveDrops = 60
    private var lastGoodSampleBuffer: CMSampleBuffer?
    private var processingGeneration: UInt64 = 0
    private let processingLock = OSAllocatedUnfairLock()

    init(mediaMixer: MediaMixer,
        sendlog: @escaping (String) -> Void) {
        self.mediaMixer = mediaMixer
        self.sendlog = sendlog
        self.isActive = true
        self.hasPublished = false
        self.processorActor = ProcessorActor(
            debug: RPConfig.shared.enableRotateLog,
            sendlog: sendlog
        )
        self.angle = RotationAngle(
                rawValue: UInt32(RPConfig.shared.state.Rotate)
            ) ?? .landscapeRight
        self.updateRotateFixState()
    }

    private func makeProcessorActor() -> ProcessorActor {
        ProcessorActor(
            debug: RPConfig.shared.enableRotateLog,
            sendlog: sendlog
        )
    }

    private func resetProcessorActor(reason: String) {
        let oldActor = processorActor
        processorActor = nil
        processingLock.withLock { processingGeneration &+= 1 }
        Task { await oldActor?.cleanup() }
        sendlog(reason)
    }

    func cleanup() {
        isActive = false
        let oldActor = processorActor
        processorActor = nil
        processingLock.withLock { processingGeneration &+= 1 }
        Task { await oldActor?.cleanup() }
    }

    func resetProcessing() {
        processingLock.withLock {
            isProcessing = false
            processingStartedAt = nil
            watchdogResetCount = 0
            consecutiveDropCount = 0
            lastGoodSampleBuffer = nil
            processingGeneration &+= 1
        }
    }

    func setRotatorDebug(_ value: Bool) async {
        await processorActor?.updateDebug(value)
    }

    func setRotatorTsDebug(_ value: Bool) async {
        await processorActor?.updateTsDebug(value)
    }

    func setRotatorDestination(width: Int, height: Int) async {
        await processorActor?.updateDestination(width: width, height: height)
    }

    deinit {
        cleanup()
        sendlog("🧹 VideoFrameProcessor deinit — resources released")
    }

    func process(_ sampleBuffer: CMSampleBuffer, oringinaltime: CMSampleTimingInfo) {
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }

        let pts = oringinaltime.presentationTimeStamp
        processedCount += 1
        let localCount = processedCount

        // ✅ 強制診斷：每 60 幀 / 1500 輸出，確認 process() 有被呼叫
        if localCount == 60 || localCount % 1500 == 0 {
            sendlog("[VProc] #\(localCount) PTS:\(String(format:"%.3f",pts.seconds))s active:\(isActive) processing:\(isProcessing)")
        }

        // Watchdog + check-and-set（原子操作）
        // Watchdog + check-and-set（原子操作）
        enum LockAction { case proceed, skip, deactivate, reset }
        let (action, capturedGeneration) = processingLock.withLock { () -> (LockAction, UInt64) in
            // Watchdog: 偵測 GPU 旋轉逾時
            if isProcessing, let startedAt = processingStartedAt {
                if Date().timeIntervalSince(startedAt) > processingTimeout {
                    isProcessing = false
                    processingStartedAt = nil
                    return (.reset, 0)
                }
            }

            // 連續逾時重置超過上限
            if watchdogResetCount > 3 {
                return (.deactivate, 0)
            }

            guard !isProcessing else { return (.skip, 0) }
            isProcessing = true
            processingStartedAt = Date()
            processingGeneration &+= 1
            return (.proceed, processingGeneration)
        }

        switch action {
        case .reset:
            watchdogResetCount += 1
            resetProcessorActor(
                reason: "[VideoProcessor] ⚠️ #\(processedCount) GPU 處理逾時 (\(Int(processingTimeout))s)，重置旋轉器管線 (#\(watchdogResetCount))"
            )
        case .deactivate:
            isActive = false
            sendlog("[VideoProcessor] ❌ 連續 GPU 逾時超過上限，標記重建")
            return
        case .skip:
            return
        case .proceed:
            break
        }

        let taskGeneration = capturedGeneration

        let isFirstFrame = localCount == 1
        let enablePipeLog = RPConfig.shared.enablePipelineLog

        if enablePipeLog, isFirstFrame || localCount % 300 == 0 {
            sendlog("[VideoProcessor] #\(localCount) 進入 PTS:\(String(format:"%.3f",pts.seconds))s")
        }

        // 確保 actor 存在（可能被 watchdog 清掉了）
        if processorActor == nil {
            processorActor = makeProcessorActor()
        }
        guard let actor = processorActor else {
            isProcessing = false
            processingStartedAt = nil
            return
        }

        Task.detached(priority: .high) { [weak self] in
            guard let self else { return }
            defer {
                self.processingLock.withLock {
                    if self.processingGeneration == taskGeneration {
                        self.isProcessing = false
                        self.processingStartedAt = nil
                    }
                }
            }
            guard self.isActive else { return }

            guard let rotated = await actor.processFrame(
                imageBuffer: imageBuffer,
                originalTime: oringinaltime,
                angle: self.angle
            ) else {
                self.consecutiveDropCount += 1
                if self.consecutiveDropCount == self.fallbackFreezeThreshold {
                    sendlog("[VideoProcessor] ⚠️ Metal 旋轉連續失敗，啟用最後好幀 fallback 保持下游 video")
                } else if self.consecutiveDropCount > self.fallbackFreezeThreshold,
                          self.consecutiveDropCount % 60 == 0 {
                    sendlog("[VideoProcessor] ⚠️ Metal 旋轉仍失敗 \(self.consecutiveDropCount) 幀，持續 fallback")
                }

                if self.consecutiveDropCount >= self.maxConsecutiveDrops {
                    self.isActive = false
                    sendlog("[VideoProcessor] ❌ 連續 \(self.consecutiveDropCount) 幀旋轉失敗，標記重建")
                    self.lastGoodSampleBuffer = nil
                    return
                }

                guard self.consecutiveDropCount >= self.fallbackFreezeThreshold,
                      let fallback = self.makeRetimedCopy(
                        from: self.lastGoodSampleBuffer,
                        pts: pts,
                        originalTime: oringinaltime
                      ) else {
                    return
                }

                guard await self.mediaMixer.isRunning else {
                    if enablePipeLog {
                        sendlog("[VideoProcessor] ⚠️ #\(localCount) MediaMixer 未運行，fallback 跳過 PTS:\(String(format:"%.3f",pts.seconds))s")
                    }
                    return
                }

                self.sentCount += 1
                await self.mediaMixer.append(fallback)
                if enablePipeLog, self.consecutiveDropCount == self.fallbackFreezeThreshold {
                    sendlog("[VideoProcessor] #\(localCount) fallback 最後好幀 PTS:\(String(format:"%.3f",pts.seconds))s")
                }
                return
            }

            // 成功處理，重置所有計數
            self.watchdogResetCount = 0
            self.consecutiveDropCount = 0

            let duration: CMTime
            if oringinaltime.duration.isValid, oringinaltime.duration.seconds > 0 {
                duration = oringinaltime.duration
            } else {
                duration = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
            }
            var correctedTiming = CMSampleTimingInfo(
                duration: duration,
                presentationTimeStamp: pts,
                decodeTimeStamp: CMTime.invalid
            )
            var correctedBuffer: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: rotated,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &correctedTiming,
                sampleBufferOut: &correctedBuffer
            )
            let outputBuffer = correctedBuffer ?? rotated
            self.lastGoodSampleBuffer = outputBuffer

            guard await self.mediaMixer.isRunning else {
                if enablePipeLog {
                    sendlog("[VideoProcessor] ⚠️ #\(localCount) MediaMixer 未運行，跳過 PTS:\(String(format:"%.3f",pts.seconds))s")
                }
                return
            }
            self.sentCount += 1
            if enablePipeLog, isFirstFrame || localCount % 300 == 0 {
                sendlog("[VideoProcessor] #\(localCount) 送出MediaMixer PTS:\(String(format:"%.3f",pts.seconds))s")
            }
            await self.mediaMixer.append(outputBuffer)
        }
    }

    private func makeRetimedCopy(
        from sampleBuffer: CMSampleBuffer?,
        pts: CMTime,
        originalTime: CMSampleTimingInfo
    ) -> CMSampleBuffer? {
        guard let sampleBuffer else { return nil }

        let duration: CMTime
        if originalTime.duration.isValid, originalTime.duration.seconds > 0 {
            duration = originalTime.duration
        } else {
            duration = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: CMTime.invalid
        )
        var copied: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copied
        )
        return copied
    }


}


