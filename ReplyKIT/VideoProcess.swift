import HaishinKit
import RTMPHaishinKit
import ReplayKit
import CoreMedia


final class VideoFrameProcessor {
    // 初始化 RotatorPool（在 SampleHandler 或初始化時）
    var rotator: RPVideoRotatorNV12BatchQueueOptimized?

    private let mediaMixer: MediaMixer

    private let queue = DispatchQueue(
        label: "video.processor.queue"
    )

    private let gpuSemaphore = DispatchSemaphore(value: 5)

    private let sendlog: (String) -> Void

    var Rotate = RPConfig.shared.state.Rotate

    private func updateNoiseFixState() {

        let current = RPConfig.shared.state.Rotate

        guard current != Rotate else { return }

        Rotate = current

        if current != Rotate {
            sendlog("🟢 New Rotate \(current)")
        } else {
            sendlog("🔴 Old Rotate \(Rotate)")
                
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

        self.updateNoiseFixState()
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


    func process(_ sampleBuffer: CMSampleBuffer,oringinaltime: CMSampleTimingInfo) {

        let res = gpuSemaphore.wait(timeout: .now() + .milliseconds(5))

        self.updateVideoFixState()
        
        if res == .timedOut {
            if debug {
                sendlog("GPU Semaphore wait timed out - skipping frame to avoid deadlock")
            }
            return
        } else if res == .success {
            if debug {
            // Handle successful wait
            sendlog("GPU Semaphore wait succeeded")

            }
        }
        
        queue.async { [weak self] in

            guard let self = self, self.isActive else { return }

            if rotator == nil {
                let dstRW = RPConfig.shared.state.ADWidth
                let dstRH = RPConfig.shared.state.ADHeight
                let outW = RPConfig.shared.state.ODWidth
                let outH = RPConfig.shared.state.ODHeight

                let mode: RPVideoRotatorNV12BatchQueueOptimized.QualityMode =
                    RPConfig.shared.state.useBic ? .quality : .live

                rotator = RPVideoRotatorNV12BatchQueueOptimized(
                    dstW: dstRW,
                    dstH: dstRH,
                    outW: outW,
                    outH: outH,
                    debug: debug,
                    useBic: mode
                )

                if rotator == nil {
                    print("❌ Rotator init failed")
                    return
                }
            }

            guard let rotator else { return }

            let angle = RotationAngle(
                rawValue: UInt32(Rotate)
            ) ?? .landscapeRight


            Task {

                defer { self.gpuSemaphore.signal() }

            guard let rotated = await rotator.rotateAsync(
                sampleBuffer: sampleBuffer,
                originalTime: oringinaltime,
                angle: angle
            ) else {
                print("GPU Fail!")
                return
            }

            
                await self.mediaMixer.append(rotated)
            }
        }


    

    }


}



