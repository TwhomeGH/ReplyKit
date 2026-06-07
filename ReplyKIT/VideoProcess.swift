import HaishinKit
import RTMPHaishinKit
import ReplayKit
import CoreMedia


final class VideoFrameProcessor {
    // CFR 平滑：frameCount 產生恒定 PTS，避免 VFR 造成 B-frame 重排序損毀
    private var frameCount: Int64 = 0
    private let targetFPS: Int32 = 60

    // 初始化 RotatorPool（在 SampleHandler 或初始化時）
    var rotator: RPVideoRotatorNV12BatchQueueOptimized? = nil

    private let mediaMixer: MediaMixer

    private let queue = DispatchQueue(
        label: "video.processor.queue"
    )

    private let sendlog: (String) -> Void

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

        // Task 目前無法強制取消，確保 isActive 檢查能立即返回
        Task {
            if (rotator != nil) {
                await rotator?.cleanup()
                rotator = nil
            }

        }
    }
    deinit {
        cleanup()
        sendlog("🧹 VideoFrameProcessor deinit — resources released")
    }

    


    func process(_ sampleBuffer: CMSampleBuffer, oringinaltime: CMSampleTimingInfo) {
        Task { [weak self] in
            guard let self = self, self.isActive else { return }

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
                sampleBuffer: sampleBuffer,
                originalTime: oringinaltime,
                angle: self.angle
            ) else { return }

            // CFR 平滑：以 frameCount 產生恒定 PTS，消除 VFR 造成的 PTS 抖動
            let correctedPTS = CMTime(value: frameCount, timescale: targetFPS)
            var correctedTiming = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: targetFPS),
                presentationTimeStamp: correctedPTS,
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
            frameCount += 1

            if let cb = correctedBuffer {
                await self.mediaMixer.append(cb)
            } else {
                await self.mediaMixer.append(rotated)
            }
        }
    }


}



