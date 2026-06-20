import HaishinKit
import RTMPHaishinKit
import ReplayKit
import CoreMedia


final class VideoFrameProcessor {
    private actor RotatorManager {
        private var rotator: RPVideoRotatorNV12BatchQueueOptimized?
        private var lastKey: (useBic: Bool, dstW: Int, dstH: Int, outW: Int, outH: Int, RotateOriginal: Bool)?
        private let sendlog: (String) -> Void
        private var debug: Bool

        init(debug: Bool, sendlog: @escaping (String) -> Void) {
            self.debug = debug
            self.sendlog = sendlog
        }

        func getOrCreateRotator() async -> RPVideoRotatorNV12BatchQueueOptimized? {
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
    private let rotatorManager: RotatorManager

    // 限制同時 inflight frame 數量，避免 GPU 積壓
    private var inflightCount = 0
    private let inflightLock = NSLock()
    private var lastDropLog: CFTimeInterval = 0

    private func acquireSlot() -> Bool {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        guard inflightCount < 8 else { return false }
        inflightCount += 1
        return true
    }

    private func releaseSlot() {
        inflightLock.lock()
        inflightCount -= 1
        inflightLock.unlock()
    }

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
        self.rotatorManager = RotatorManager(
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
        Task { await rotatorManager.cleanup() }
    }

    func setRotatorDebug(_ value: Bool) async {
        await rotatorManager.updateDebug(value)
    }

    func setRotatorTsDebug(_ value: Bool) async {
        await rotatorManager.updateTsDebug(value)
    }

    func setRotatorDestination(width: Int, height: Int) async {
        await rotatorManager.updateDestination(width: width, height: height)
    }

    deinit {
        cleanup()
        sendlog("🧹 VideoFrameProcessor deinit — resources released")
    }


    func process(_ sampleBuffer: CMSampleBuffer, oringinaltime: CMSampleTimingInfo) {
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        Task { [weak self] in
            guard let self = self, self.isActive else { return }
            guard self.acquireSlot() else {
                let now = CACurrentMediaTime()
                if now - lastDropLog > 1.0 {
                    lastDropLog = now
                    sendlog("⚠️ VideoProcessor: dropping frame (inflight=8)")
                }
                return
            }
            defer { self.releaseSlot() }

            guard let rotator = await rotatorManager.getOrCreateRotator() else { return }

            guard let rotated = await rotator.rotateAsync(
                pixelBuffer: imageBuffer,
                originalTime: oringinaltime,
                angle: self.angle
            ) else { return }

            let pts = oringinaltime.presentationTimeStamp
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

            guard await mediaMixer.isRunning else {
                return
            }
            if let cb = correctedBuffer {
                await self.mediaMixer.append(cb)
            } else {
                await self.mediaMixer.append(rotated)
            }
        }
    }


}



