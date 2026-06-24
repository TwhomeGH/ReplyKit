import HaishinKit
import RTMPHaishinKit
import ReplayKit
import CoreMedia


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
    private let processorActor: ProcessorActor

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

    func cleanup() {
        isActive = false
        Task { await processorActor.cleanup() }
    }

    func setRotatorDebug(_ value: Bool) async {
        await processorActor.updateDebug(value)
    }

    func setRotatorTsDebug(_ value: Bool) async {
        await processorActor.updateTsDebug(value)
    }

    func setRotatorDestination(width: Int, height: Int) async {
        await processorActor.updateDestination(width: width, height: height)
    }

    deinit {
        cleanup()
        sendlog("🧹 VideoFrameProcessor deinit — resources released")
    }

    func process(_ sampleBuffer: CMSampleBuffer, oringinaltime: CMSampleTimingInfo) {
        guard let imageBuffer = sampleBuffer.imageBuffer, !isProcessing else { return }
        isProcessing = true
        let pts = oringinaltime.presentationTimeStamp
        processedCount += 1
        let localCount = processedCount
        let isFirstFrame = localCount == 1
        let enablePipeLog = RPConfig.shared.enablePipelineLog

        if enablePipeLog, isFirstFrame || localCount % 300 == 0 {
            sendlog("[VideoProcessor] #\(localCount) 進入 PTS:\(String(format:"%.3f",pts.seconds))s")
        }

        Task.detached(priority: .utility) { [weak self] in
            guard let self, self.isActive else { self?.isProcessing = false; return }
            defer { self.isProcessing = false }

            guard let rotated = await self.processorActor.processFrame(
                imageBuffer: imageBuffer,
                originalTime: oringinaltime,
                angle: self.angle
            ) else {
                if enablePipeLog {
                    sendlog("[VideoProcessor] ⚠️ #\(localCount) 旋轉失敗 PTS:\(String(format:"%.3f",pts.seconds))s")
                }
                return
            }

            if enablePipeLog, isFirstFrame || localCount % 300 == 0 {
                sendlog("[VideoProcessor] #\(localCount) 旋轉完成 PTS:\(String(format:"%.3f",pts.seconds))s")
            }

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
            if let cb = correctedBuffer {
                await self.mediaMixer.append(cb)
            } else {
                await self.mediaMixer.append(rotated)
            }
        }
    }


}



