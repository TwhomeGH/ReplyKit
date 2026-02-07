import HaishinKit
import RTMPHaishinKit
import ReplayKit
import CoreMedia


final class VideoFrameProcessor {
    // 初始化 RotatorPool（在 SampleHandler 或初始化時）
    var rotator: RPVideoRotatorNV12BatchQueueOptimized?

    private let mediaMixer: MediaMixer
   

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


//
//        sendlog("GPU旋轉配置:\(Debugg) Bic:\(Bic) maxInflight:\(maxInflight) \(dstRW) x \(dstRH)")
//

    }
    func cleanup() {
        isActive = false


        // Task 目前無法強制取消，確保 isActive 檢查能立即返回

        Task {
            await rotator?.cleanup()
            rotator = nil

        }
    }
    deinit {
        sendlog("🧹 VideoFrameProcessor deinit — resources released")
    }

    private func processFrame(
        _ sampleBuffer: CMSampleBuffer,
        timestamp: CMTime
    ) async {
        guard isActive else { return }
        guard !Task.isCancelled else { return }

        // lazy init rotator（現在是安全的）
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
                sendlog("❌ Rotator init failed")
                return
            }
        }

        guard let rotator else { return }

        let angle = RotationAngle(
            rawValue: UInt32(RPConfig.shared.Rotate)
        ) ?? .landscapeRight

        let rotated = await rotator.rotateAsync(
            sampleBuffer: sampleBuffer,
            angle: angle
        )

        guard isActive, !Task.isCancelled else { return }

        if let rotated {
            await mediaMixer.append(rotated)
        } else {
            self.sendlog("GPU Fail!")
        }

    }


    func process(_ sampleBuffer: CMSampleBuffer, timestamp: CMTime) {

        Task(priority: .userInitiated) {
                await processFrame(sampleBuffer, timestamp: timestamp)
            }

    }



}



