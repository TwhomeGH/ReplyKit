import HaishinKit
import RTMPHaishinKit
import ReplayKit
import CoreMedia


final class VideoFrameProcessor {
    var rotator: RPVideoRotatorNV12BatchQueueOptimized? = nil

    private let mediaMixer: MediaMixer

    private let queue = DispatchQueue(
        label: "video.processor.queue"
    )

    private let sendlog: (String) -> Void

    // 限制同時 inflight frame 數量，避免 GPU 積壓
    private var inflightCount = 0
    private let inflightLock = NSLock()
    private var lastDropLog: CFTimeInterval = 0

    private func acquireSlot() -> Bool {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        guard inflightCount < 4 else { return false }
        inflightCount += 1
        return true
    }

    private func releaseSlot() {
        inflightLock.lock()
        inflightCount -= 1
        inflightLock.unlock()
    }

    private var lastRotatorKey: (useBic: Bool, dstW: Int, dstH: Int, outW: Int, outH: Int, RotateOriginal: Bool)?


    var angle = RotationAngle(
                rawValue: UInt32(RPConfig.shared.state.Rotate)
            ) ?? .landscapeRight

    var Rotate = RPConfig.shared.state.Rotate

    private func updateRotateFixState() {

        let current = RPConfig.shared.state.Rotate

        guard current != Rotate else { return }

        Rotate = current

        if current != Rotate {
            sendlog("🟢 New Rotate \(current)")
        } else {
            sendlog("🔴 Old Rotate \(Rotate)")
                
        }
    }


    private func updateVideoFixState() {

        let current = RPConfig.shared.enableRotateLog

        guard current != debug else { return }

        debug = current

        if debug {
            sendlog("🔄 Rotate Log Enabled")
        } else {
            sendlog("🔄 Rotate Log Disabled")

        }

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


        self.angle = RotationAngle(
                rawValue: UInt32(RPConfig.shared.state.Rotate)
            ) ?? .landscapeRight

        self.updateRotateFixState()
        self.updateVideoFixState()
    }
    func cleanup() {
        isActive = false
        let r = rotator
        rotator = nil
        if let r = r {
            Task { await r.cleanup() }
        }
    }
    deinit {
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
                    sendlog("⚠️ VideoProcessor: dropping frame (inflight=4)")
                }
                return
            }
            defer { self.releaseSlot() }

            guard let rotator = queue.sync(execute: { () -> RPVideoRotatorNV12BatchQueueOptimized? in
                let key = (
                    useBic: RPConfig.shared.state.useBic,
                    dstW: RPConfig.shared.state.ADWidth,
                    dstH: RPConfig.shared.state.ADHeight,
                    outW: RPConfig.shared.state.ODWidth,
                    outH: RPConfig.shared.state.ODHeight,
                    RotateOriginal: RPConfig.shared.state.RotateOriginal
                )
                if let r = self.rotator, let last = self.lastRotatorKey, last != key {
                    let old = r
                    Task { await old.cleanup() }
                    self.rotator = nil
                    self.sendlog("[Rotator] config changed, recreating")
                }
                self.lastRotatorKey = key

                if let r = self.rotator { return r }
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
                    debug: self.debug,
                    useBic: mode,
                    RotateOriginal: RotateOriginal
                ) else {
                    // Swift 6.0語法須明確self使用
                    
                    self.sendlog("GPU Rotator init failed")
                    return nil
                }
                self.rotator = r
                return r
            }) else { return }

            guard let rotated = await rotator.rotateAsync(
                pixelBuffer: imageBuffer,
                originalTime: oringinaltime,
                angle: self.angle
            ) else { return }

            // 使用 ReplayKit 原始 PTS / duration，確保影音同一 timebase
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

            if let cb = correctedBuffer {
                await self.mediaMixer.append(cb)
            } else {
                await self.mediaMixer.append(rotated)
            }
        }
    }


}



