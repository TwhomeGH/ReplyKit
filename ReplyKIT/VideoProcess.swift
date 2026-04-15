import HaishinKit
import RTMPHaishinKit
import ReplayKit
import CoreMedia



actor FramePipeline {

    private var rotator: RPVideoRotatorNV12BatchQueueOptimized?
    private let mediaMixer: MediaMixer
    private let audioProcess: AudioProcessor
    
    private var latestBuffer: CMSampleBuffer?
    private var isRunning = false

    init(mediaMixer: MediaMixer,audioProcess:AudioProcessor) {
        self.mediaMixer = mediaMixer
        self.audioProcess = audioProcess
    }

    // 外部丟幀進來
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        latestBuffer = sampleBuffer // 只保留最新幀（低延遲策略）
        if !isRunning {
            isRunning = true
            Task {
                await self.processLoop()
            }
        }
    }

    private func processLoop() async {
        while let buffer = latestBuffer {
            latestBuffer = nil
            await processFrame(buffer)
        }
        isRunning = false
    }

    private func processFrame(_ sampleBuffer: CMSampleBuffer) async {
        guard !Task.isCancelled else { return }

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
                useBic: mode,
                audioProcess:audioProcess
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

        guard let rotated = await rotator.rotateAsync(
            sampleBuffer: sampleBuffer,
            angle: angle
        ) else {
            print("GPU Fail!")
            return
        }

        await mediaMixer.append(rotated)
    }
}


final class VideoFrameProcessor {
    // 初始化 RotatorPool（在 SampleHandler 或初始化時）
    var rotator: RPVideoRotatorNV12BatchQueueOptimized?

    private let mediaMixer: MediaMixer
    private let audioProcess: AudioProcessor

    
    
    private let sendlog: (String) -> Void

    var Rotate = RPConfig.shared.Rotate

    var isActive = true

    var hasPublished = false

    private lazy var pipeline = FramePipeline(mediaMixer: mediaMixer)

    init(mediaMixer: MediaMixer,audioProcess:AudioProcessor
         sendlog: @escaping (String) -> Void) {
        self.mediaMixer = mediaMixer

        self.audioProces = audioProcess
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

    func process(_ sampleBuffer: CMSampleBuffer) {
        Task {
            await pipeline.enqueue(sampleBuffer)
        }
    }


}



