import HaishinKit
import RTMPHaishinKit
import ReplayKit
import CoreMedia



final class VideoFrameProcessor {
    // 初始化 RotatorPool（在 SampleHandler 或初始化時）
    var rotator: RPVideoRotatorNV12Queue?


    private let mediaMixer: MediaMixer
    private let videoBufferManager: AdaptiveVideoBufferManager
    //private var rotator: VideoRotator?
    private let rtmpStream: RTMPStream
    private let sendlog: (String) -> Void
    private let processingQueue = DispatchQueue(label: "video.processor.queue", qos: .userInitiated)

    var isActive = true


    init(mediaMixer: MediaMixer,
         videoBufferManager: AdaptiveVideoBufferManager,
         
         rtmpStream: RTMPStream,
         sendlog: @escaping (String) -> Void) {
        self.mediaMixer = mediaMixer
        self.videoBufferManager = videoBufferManager

        self.rtmpStream = rtmpStream
        self.sendlog = sendlog
        self.isActive = true

        logger.debug("準備初始化Rotator!")
        let Bic=userDefaults?.bool(forKey: "useBic") ?? false


        let maxInflight=userDefaults?.integer(forKey: "MaxInfilght") ?? 4
        let Debugg=userDefaults?.bool(forKey: "EnableRotatelog") ?? false

        let dstRW=userDefaults?.integer(forKey: "dstW") ?? 0

        let dstRH=userDefaults?.integer(forKey: "dstH") ?? 0


        sendlog("GPU旋轉配置:\(Debugg) Bic:\(Bic) maxInflight:\(maxInflight) \(dstRW) x \(dstRH)")

        guard let rot = RPVideoRotatorNV12Queue(
            //maxInflight: maxInflight,
            dstW: dstRW,
            dstH: dstRH,
            useBic: Bic,
            debug: Debugg
        ) else {
            sendlog("RPVideoRotatorNV12Queue 初始化失敗")
            return
        }
        self.rotator = rot

        
        
    }
    func cleanup() {
        isActive = false
        // 清空 queue 上未執行的任務
        processingQueue.sync {


        } // 確保之前的所有 block 都完成
        // Task 目前無法強制取消，確保 isActive 檢查能立即返回

        rotator?.cleanup()



    }
    deinit {
        
        cleanup()

        rotator = nil
        sendlog("🧹 VideoFrameProcessor deinit — resources released")
    }


    func process(_ sampleBuffer: CMSampleBuffer, timestamp: CMTime) {

        processingQueue.async { [weak self] in
            guard let self = self, self.isActive else { return }


            self.processFrame(sampleBuffer)

        }



    }


    private func processFrame(_ sample: CMSampleBuffer) {


        Task(priority: .userInitiated) { [weak self] in
                guard let self = self, self.isActive else { return }

                        if let rotated = await self.rotator?.rotateAsync(sampleBuffer: sample, angle: .angle90) {
                            await self.mediaMixer.append(rotated)
                        }
            

            }


                        // FPS 調整與 log trace
                        self.videoBufferManager.monitorFPSAndAdjust(
                            with: sample,
                            rtmpStream: rtmpStream,
                            sendlog: sendlog
                        )





    }
}



