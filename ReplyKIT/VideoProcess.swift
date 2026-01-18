import HaishinKit
import RTMPHaishinKit
import ReplayKit
import CoreMedia


actor FrameTaskManager {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func add(_ id: UUID, task: Task<Void, Never>) {
        tasks[id] = task
    }

    func remove(_ id: UUID) {
        tasks.removeValue(forKey: id)
    }

    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
    }
}

final class VideoFrameProcessor {
    // 初始化 RotatorPool（在 SampleHandler 或初始化時）
    var rotator: RPVideoRotatorNV12BatchQueueOptimized?

    private let frameTaskManager = FrameTaskManager()

    private let mediaMixer: MediaMixer
    //private var rotator: VideoRotator?
    private let rtmpStream: RTMPStream
    private let sendlog: (String) -> Void
    private let processingQueue = DispatchQueue(label: "video.processor.queue", qos: .userInitiated)

    var Rotate = RPConfig.shared.Rotate

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

        // 1️⃣ cancel 所有尚未完成的 frame task
        Task {
            await self.frameTaskManager.cancelAll()
        }




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

        processingQueue.async { [weak self] in
            guard let self = self, self.isActive else { return }

            guard self.isActive else { return }

            // 延遲初始化 rotator
            if self.rotator == nil {

                let Debugg = RPConfig.shared.enableRotateLog

                let dstRW = RPConfig.shared.ADWidth
                let dstRH = RPConfig.shared.ADHeight

                let useBic = RPConfig.shared.useBic

                let mode: RPVideoRotatorNV12BatchQueueOptimized.QualityMode = useBic ? .quality : .live

                if let rot = RPVideoRotatorNV12BatchQueueOptimized(
                    dstW: dstRW,
                    dstH: dstRH,
                    debug: Debugg,
                    useBic: mode
                ) {
                    self.rotator = rot
                    self.sendlog("🟢 RPVideoRotatorNV12BatchQueue 延遲初始化成功")
                } else {
                    self.sendlog("❌ RPVideoRotatorNV12BatchQueue 初始化失敗")
                    return
                }
            }

            let taskID = UUID()

            // 保留 rotator 強引用直到 Task 完成
            let task = Task(priority: .userInitiated) { [weak self, rotator] in

                guard let self else { return }
                guard !Task.isCancelled else { return }
                guard self.isActive else { return }
                guard let rotator else { return }

                let RotateAngle = UInt32(RPConfig.shared.Rotate)

                let rotated = await rotator.rotateAsync(
                    sampleBuffer: sampleBuffer,
                    angle: RotationAngle(
                        rawValue: RotateAngle
                    ) ?? .landscapeRight
                )

                guard !Task.isCancelled, self.isActive else { return }

                if let rotated {
                    await self.mediaMixer.append(rotated)
                } else {
                    self.sendlog("GPU Fail!")
                }

                // 🧹 Task 結束時移除自己
                await self.frameTaskManager.remove(taskID)

            }

            // 記錄 Task
            Task {
                await self.frameTaskManager.add(taskID, task: task)
            }





        }



    }



}



