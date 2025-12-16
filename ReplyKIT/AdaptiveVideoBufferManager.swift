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


public final class InitialVideoBufferEstimator {

    private let minBufferCount = 2
    private let maxBufferCount = 5
    private let targetFPS: Double = 30.0
    private let emaAlpha: Double = 0.2

    private var smoothedFPS: Double = 0
    private var lastFrameTime: Double = 0

    private(set) var estimatedBufferCount: Int

    private var frameCount: Int = 0
    private let minFrames: Int = 12   // 8~15 都可以

    private var lastFPS: Double = 0

    public var isReady: Bool {
        frameCount >= minFrames
    }

    public init() {
        let cores = ProcessInfo.processInfo.processorCount
        if cores >= 8 {
            estimatedBufferCount = 4
        } else if cores >= 4 {
            estimatedBufferCount = 3
        } else {
            estimatedBufferCount = 2
        }
    }

    /// 在「開播前預熱階段」餵幾十幀進來
    public func ingest(sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard lastFrameTime > 0 else {
            lastFrameTime = pts
            return
        }

        let delta = pts - lastFrameTime
        lastFrameTime = pts
        guard delta > 0 else { return }

        frameCount += 1

        let fps = 1.0 / delta
        smoothedFPS = smoothedFPS == 0
            ? fps
            : emaAlpha * fps + (1 - emaAlpha) * smoothedFPS

        if smoothedFPS < targetFPS * 0.7 {
            estimatedBufferCount = min(estimatedBufferCount + 1, maxBufferCount)
        }

        lastFPS = smoothedFPS
        
    }
}


private extension Array where Element == Double {
    func average() -> Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
}
