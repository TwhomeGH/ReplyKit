import HaishinKit
import RTMPHaishinKit
import ReplayKit
import CoreMedia



final class VideoFrameProcessor {
    // 初始化 RotatorPool（在 SampleHandler 或初始化時）
    var rotator: RPVideoRotatorNV12BatchQueueOptimized?


    private let mediaMixer: MediaMixer
    //private var rotator: VideoRotator?
    private let rtmpStream: RTMPStream
    private let sendlog: (String) -> Void
    private let processingQueue = DispatchQueue(label: "video.processor.queue", qos: .userInitiated)

    var isActive = true

    var hasPublished = false

    init(mediaMixer: MediaMixer,

         rtmpStream: RTMPStream,
         sendlog: @escaping (String) -> Void) {
        self.mediaMixer = mediaMixer
        self.rtmpStream = rtmpStream
        self.sendlog = sendlog
        self.isActive = true
        self.hasPublished = false


//
//        sendlog("GPU旋轉配置:\(Debugg) Bic:\(Bic) maxInflight:\(maxInflight) \(dstRW) x \(dstRH)")
//

    }
    func cleanup() {
        isActive = false
        // 清空 queue 上未執行的任務
        processingQueue.sync {


        } // 確保之前的所有 block 都完成


        // Task 目前無法強制取消，確保 isActive 檢查能立即返回

        Task {
            await rotator?.cleanup()
            rotator = nil

        }
    }
    deinit {
        sendlog("🧹 VideoFrameProcessor deinit — resources released")
    }


    func process(_ sampleBuffer: CMSampleBuffer, timestamp: CMTime) {

        processingQueue.async {
            guard self.isActive else { return }

            // 延遲初始化 rotator
            if self.rotator == nil {
                let Bic = SharedDefaults.group?.bool(forKey: "useBic") ?? false
                let Debugg = SharedDefaults.group?.bool(forKey: "EnableRotatelog") ?? false
                let dstRW = SharedDefaults.group?.integer(forKey: "dstW") ?? 0
                let dstRH = SharedDefaults.group?.integer(forKey: "dstH") ?? 0

                if let rot = RPVideoRotatorNV12BatchQueueOptimized(
                    dstW: dstRW,
                    dstH: dstRH,
                    useBic: Bic,
                    debug: Debugg
                ) {
                    self.rotator = rot
                    self.sendlog("🟢 RPVideoRotatorNV12BatchQueue 延遲初始化成功")
                } else {
                    self.sendlog("❌ RPVideoRotatorNV12BatchQueue 初始化失敗")
                    return
                }
            }


            Task(priority: .userInitiated) { [weak self] in
                guard let self = self, self.isActive else { return }



                if let rotated = await self.rotator?.rotateAsync(
                    sampleBuffer: sampleBuffer,
                    angle: .angle90
                ) {
                    await self.mediaMixer.append(rotated)
                } else {
                    sendlog("GPU Fail!")
                }




            }





        }



    }



}



