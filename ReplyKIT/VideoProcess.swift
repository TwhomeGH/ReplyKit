import HaishinKit
import RTMPHaishinKit
import ReplayKit
import CoreMedia


final class VideoFrameProcessor {
    // 初始化 RotatorPool（在 SampleHandler 或初始化時）
    var rotator: RPVideoRotatorNV12BatchQueueOptimized?

    private let mediaMixer: MediaMixer

    private let queue = DispatchQueue(
        label: "video.processor.queue",
        qos: .utility
    )

    private let sendlog: (String) -> Void

    var Rotate = RPConfig.shared.Rotate

    var isActive = true

    var hasPublished = false


    init(mediaMixer: MediaMixer,
        sendlog: @escaping (String) -> Void) {
        self.mediaMixer = mediaMixer

        self.sendlog = sendlog
        self.isActive = true
        self.hasPublished = false

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


    func process(_ sampleBuffer: CMSampleBuffer,oringinaltime: CMSampleTimingInfo) {

        queue.async { [weak self] in

            guard let self = self, self.isActive else { return }

            if rotator == nil {
                let dstRW = RPConfig.shared.ADWidth
                let dstRH = RPConfig.shared.ADHeight
                let mode: RPVideoRotatorNV12BatchQueueOptimized.QualityMode =
                    RPConfig.shared.useBic ? .quality : .live

                rotator = RPVideoRotatorNV12BatchQueueOptimized(
                    dstW: dstRW,
                    dstH: dstRH,
                    debug: RPConfig.shared.enableRotateLog,
                    maxPoolSize: RPConfig.shared.BufferCount,
                    useBic: mode
                )

                if rotator == nil {
                    print("❌ Rotator init failed")
                    return
                }
            }

            guard let rotator else { return }

            let angle = RotationAngle(
                rawValue: UInt32(RPConfig.shared.Rotate)
            ) ?? .landscapeRight


            Task {

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



