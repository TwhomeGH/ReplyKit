import HaishinKit
import RTMPHaishinKit
import ReplayKit
import CoreMedia



actor FramePipeline {

    private var rotator: RPVideoRotatorNV12BatchQueueOptimized?
    private let mediaMixer: MediaMixer
    
    private var latestBuffer: CMSampleBuffer?
    private var latestPTS: CMSampleTimingInfo?
    
    private var isRunning = false

    init(mediaMixer: MediaMixer) {
        self.mediaMixer = mediaMixer
    }

    // 外部丟幀進來
    func enqueue(_ sampleBuffer: CMSampleBuffer,oringinaltime: CMSampleTimingInfo) {
        latestBuffer = sampleBuffer // 只保留最新幀（低延遲策略）
        
        latestPTS = oringinaltime 
        
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

            if let latestPTS {
                print("Processing frame with PTS: \(latestPTS.presentationTimeStamp.value)/\(latestPTS.presentationTimeStamp.timescale)")
                await processFrame(buffer,oringintime: latestPTS)
            }
            else {
                print("Processing frame with unknown PTS")
                await processFrame(buffer,oringinaltime: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid))
            
            }
            
        }
        isRunning = false
    }

    private func processFrame(_ sampleBuffer: CMSampleBuffer,oringinaltime: CMSampleTimingInfo) async {
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

        guard let rotated = await rotator.rotateAsync(
            sampleBuffer: sampleBuffer,
            originalTime: oringinaltime,
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

    private let sendlog: (String) -> Void

    var Rotate = RPConfig.shared.Rotate

    var isActive = true

    var hasPublished = false

    private lazy var pipeline = FramePipeline(mediaMixer: mediaMixer)

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
        Task {
            await pipeline.enqueue(sampleBuffer,oringinaltime: oringinaltime)
        }
    }


}



