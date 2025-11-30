import Foundation
import AVFoundation
import RTMPHaishinKit
//
//public final class AdaptiveVideoBufferManager {
//    private var currentBufferCount: Int
//    private var lastSetBufferCount: Int = -1
//    private var minBufferCount = 3
//    private var maxBufferCount = 5
//
//    private var lastFrameTime: CFTimeInterval = 0
//    private var frameIntervals: [CFTimeInterval] = []
//    private let maxSamples = 5
//
//
//    // MARK: EMA平均值
//    private var smoothedFPS: Double = 0
//    private let emaAlpha: Double = 0.2 // 建議範圍 0.1 ~ 0.3
//
//
//    private var lastAdjustTime: CFTimeInterval = 0
//    private let adjustInterval: CFTimeInterval = 1.0
//
//    private var lastStableFPS: Double = 0
//    private let hysteresisMargin: Double = 0.1
//
//    private var targetFPS: Double = 30.0
//    private let lowFPSThreshold: Double = 0.5
//    private let highFPSThreshold: Double = 1.05
//
//    private var useFixedTargetFPS = true
//    private let fixedTargetFPS: Double = 30.0
//
//    private var lastLogTime: CFTimeInterval = 0
//    private let logInterval: CFTimeInterval = 3.0
//
//    private var bufferPerformanceHistory: [Int: [Double]] = [:]
//
//    public init() {
//        let processorCount = ProcessInfo.processInfo.processorCount
//        if processorCount >= 8 {
//            currentBufferCount = 4
//        } else if processorCount >= 4 {
//            currentBufferCount = 3
//        } else {
//            currentBufferCount = 2
//        }
//        lastSetBufferCount = currentBufferCount
//    }
//
//    public func monitorFPSAndAdjust(
//        with sampleBuffer: CMSampleBuffer,
//        rtmpStream: RTMPStream,
//        sendlog: @escaping (String) -> Void
//    ) {
//        let now = CACurrentMediaTime()
//
//        var timingInfo = CMSampleTimingInfo()
//        if CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timingInfo) == noErr {
//            let duration = timingInfo.duration
//            if !useFixedTargetFPS, duration.seconds > 0 {
//                targetFPS = 1.0 / duration.seconds
//            }
//        } else if useFixedTargetFPS {
//            targetFPS = fixedTargetFPS
//        }
//
//        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
//        if lastFrameTime == 0 {
//            lastFrameTime = pts
//            return
//        }
//
//        let delta = pts - lastFrameTime
//        lastFrameTime = pts
//        guard delta > 0 else { return }
//
//        frameIntervals.append(delta)
//        if frameIntervals.count > maxSamples {
//            frameIntervals.removeFirst()
//        }
//
//        let avgDelta = frameIntervals.reduce(0, +) / Double(frameIntervals.count)
//        let fps = 1.0 / avgDelta
//        let variance = frameIntervals.reduce(0) { $0 + pow($1 - avgDelta, 2) } / Double(frameIntervals.count)
//        let stdDev = sqrt(variance)
//
//
//        if smoothedFPS == 0 {
//            smoothedFPS = fps // 初始化
//        } else {
//            smoothedFPS = emaAlpha * fps + (1 - emaAlpha) * smoothedFPS
//
//            bufferPerformanceHistory[currentBufferCount, default: []]
//                .append(smoothedFPS)
//
//        // 🎯 計算繪製延遲
//        let renderLatency = now - pts
//
//        if now - lastAdjustTime >= adjustInterval {
//            lastAdjustTime = now
//
//            let fpsDiff = abs(smoothedFPS - lastStableFPS)
//            var newBufferCount = currentBufferCount
//
//            if fpsDiff > targetFPS * hysteresisMargin || renderLatency > 0.2 || renderLatency < 0.05 {
//                lastStableFPS = smoothedFPS
//
//                if renderLatency > 0.2 || smoothedFPS < targetFPS * lowFPSThreshold {
//                    newBufferCount = min(currentBufferCount + 1, maxBufferCount)
//                } else if renderLatency < 0.05 || smoothedFPS > targetFPS * highFPSThreshold {
//                    newBufferCount = max(currentBufferCount - 1, minBufferCount)
//                }
//
//                let filtered = bufferPerformanceHistory.filter { $0.value.count >= 3 }
//                if let bestBuffer = filtered.max(by: { $0.value.average() < $1.value.average() })?.key,
//                   bestBuffer != newBufferCount {
//                    newBufferCount = bestBuffer
//                }
//
//                if newBufferCount != lastSetBufferCount {
//                    currentBufferCount = newBufferCount
//                    lastSetBufferCount = newBufferCount
//
//                    Task {
//                        await rtmpStream.setVideoInputBufferCounts(currentBufferCount)
//                    }
//                }
//            }
//        }
//
//        if now - lastLogTime >= logInterval {
//            lastLogTime = now
//            let direction = (lastSetBufferCount > currentBufferCount) ? "↑" : (lastSetBufferCount < currentBufferCount) ? "↓" : "-"
//
//
//                sendlog("ReplyKit: FPS: \(Int(smoothedFPS)) latency: \(String(format: "%.3f", renderLatency)) stdDev: \(String(format: "%.3f", stdDev)) bufferCount: \(currentBufferCount) \(direction)")
//
//        }
//    }
//}
//
//
//private extension Array where Element == Double {
//    func average() -> Double {
//        guard !isEmpty else { return 0 }
//        return reduce(0, +) / Double(count)
//    }
//}



public final class AdaptiveVideoBufferManager {
    private var currentBufferCount: Int
    private var lastSetBufferCount: Int = -1
    private var minBufferCount = 3
    private var maxBufferCount = 5

    private var lastFrameTime: CFTimeInterval = 0
    private var lastAdjustTime: CFTimeInterval = 0

    // MARK: 多久檢查一次
    var adjustInterval: CFTimeInterval = 3.0

    private var lastStableFPS: Double = 0
    private let hysteresisMargin: Double = 0.05  // 因為EMA平滑，所以可縮小

    private var targetFPS: Double = 30.0
    private let lowFPSThreshold: Double = 0.6
    private let highFPSThreshold: Double = 1.05

    private var useFixedTargetFPS = true
    private let fixedTargetFPS: Double = 30.0

    private var lastLogTime: CFTimeInterval = 0
    var logInterval: CFTimeInterval = 3.0

    // 📈 EMA 平滑變數
    private var smoothedFPS: Double = 0
    private let emaAlpha: Double = 0.2

    private var smoothedLatency: Double = 0
    private let latencyAlpha: Double = 0.2

    // 🧠 性能記錄
    private var bufferPerformanceHistory: [Int: [Double]] = [:]

    public init() {
        let processorCount = ProcessInfo.processInfo.processorCount
        if processorCount >= 8 {
            currentBufferCount = 4
        } else if processorCount >= 4 {
            currentBufferCount = 3
        } else {
            currentBufferCount = 2
        }
        lastSetBufferCount = currentBufferCount
    }

    deinit {
        sendlog(message:"動態控制緩衝釋放")
    }
    public func monitorFPSAndAdjust(
        with sampleBuffer: CMSampleBuffer,
        rtmpStream: RTMPStream,
        sendlog: @escaping (String) -> Void
    ) {
        let now = CACurrentMediaTime()

        // 🎯 目標 FPS 判斷
        var timingInfo = CMSampleTimingInfo()
        if CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timingInfo) == noErr {
            if !useFixedTargetFPS, timingInfo.duration.seconds > 0 {
                targetFPS = 1.0 / timingInfo.duration.seconds
            }
        } else if useFixedTargetFPS {
            targetFPS = fixedTargetFPS
        }

        // 🕒 幀時間計算
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if lastFrameTime == 0 {
            lastFrameTime = pts
            return
        }

        let delta = pts - lastFrameTime
        lastFrameTime = pts
        guard delta > 0 else { return }

        let fps = 1.0 / delta

        // 📊 更新 EMA 平滑 FPS
        if smoothedFPS == 0 {
            smoothedFPS = fps
        } else {
            smoothedFPS = emaAlpha * fps + (1 - emaAlpha) * smoothedFPS
        }

        // 🎯 計算繪製延遲並平滑
        let renderLatency = now - pts
        if smoothedLatency == 0 {
            smoothedLatency = renderLatency
        } else {
            smoothedLatency = latencyAlpha * renderLatency + (1 - latencyAlpha) * smoothedLatency
        }

        // 📈 儲存當前 buffer 效能紀錄
        bufferPerformanceHistory[currentBufferCount, default: []].append(smoothedFPS)

        // 限制上限 
        if bufferPerformanceHistory[currentBufferCount]!.count > 30 {
            bufferPerformanceHistory[currentBufferCount]!.removeFirst()
        }

        // 🧮 每秒調整一次 buffer
        if now - lastAdjustTime >= adjustInterval {
            lastAdjustTime = now

            let fpsDiff = abs(smoothedFPS - lastStableFPS)
            var newBufferCount = currentBufferCount

            if fpsDiff > targetFPS * hysteresisMargin ||
                smoothedLatency > 0.2 || smoothedLatency < 0.05 {

                lastStableFPS = smoothedFPS

                // FPS 過低或延遲偏高 → 增加 buffer
                if smoothedLatency > 0.2 || smoothedFPS < targetFPS * lowFPSThreshold {
                    newBufferCount = min(currentBufferCount + 1, maxBufferCount)

                // FPS 過高或延遲過低 → 減少 buffer
                } else if smoothedLatency < 0.05 || smoothedFPS > targetFPS * highFPSThreshold {
                    newBufferCount = max(currentBufferCount - 1, minBufferCount)
                }

                // 🎯 使用歷史資料學習最優解
                let filtered = bufferPerformanceHistory.filter { $0.value.count >= 3 }
                if let bestBuffer = filtered.max(by: { $0.value.average() < $1.value.average() })?.key,
                   bestBuffer != newBufferCount {
                    newBufferCount = bestBuffer
                }

                // 🧠 實際應用變更
                if newBufferCount != lastSetBufferCount {
                    currentBufferCount = newBufferCount
                    lastSetBufferCount = newBufferCount

                    Task {
                        await rtmpStream.setVideoInputBufferCounts(currentBufferCount)
                    }
                }
            }
        }

        // 🪵 每3秒輸出一次 log
        if now - lastLogTime >= logInterval {
            lastLogTime = now
            let direction = (lastSetBufferCount > currentBufferCount) ? "↑" :
                            (lastSetBufferCount < currentBufferCount) ? "↓" : "-"
            sendlog(
                "ReplyKit: EMA-FPS: \(Int(smoothedFPS)) latency: \(String(format: "%.3f", smoothedLatency)) bufferCount: \(currentBufferCount) \(direction)"
            )
        }
    }
}

private extension Array where Element == Double {
    func average() -> Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
}
