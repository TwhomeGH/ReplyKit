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

        init(debug: Bool, sendlog: @escaping (String) -> Void) {
            self.debug = debug
            self.sendlog = sendlog
        }

        func processFrame(
            imageBuffer: CVImageBuffer,
            originalTime: CMSampleTimingInfo,
            angle: RotationAngle,
            mediaMixer: MediaMixer
        ) async {
            guard let rotator = await getOrCreateRotator() else { return }

            guard let rotated = await rotator.rotateAsync(
                pixelBuffer: imageBuffer,
                originalTime: originalTime,
                angle: angle
            ) else { return }

            let pts = originalTime.presentationTimeStamp
            let duration: CMTime
            if originalTime.duration.isValid, originalTime.duration.seconds > 0 {
                duration = originalTime.duration
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

            guard await mediaMixer.isRunning else { return }
            if let cb = correctedBuffer {
                await mediaMixer.append(cb)
            } else {
                await mediaMixer.append(rotated)
            }
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
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        Task { [weak self] in
            guard let self, self.isActive else { return }
            await self.processorActor.processFrame(
                imageBuffer: imageBuffer,
                originalTime: oringinaltime,
                angle: self.angle,
                mediaMixer: self.mediaMixer
            )
        }
    }


}



