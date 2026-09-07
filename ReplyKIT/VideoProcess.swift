import HaishinKit
import RTMPHaishinKit
import ReplayKit
import Foundation
import CoreMedia
import CoreVideo
import os

struct VideoProcessorDiagnostics: Sendable {
    let isActive: Bool
    let processedCount: Int
    let droppedCount: Int
    let consecutiveDropCount: Int
    let hasGpuRotator: Bool
    let gpuPermanentFailure: Bool
    let commandStats: GPUCommandStats

    var summary: String {
        "active:\(isActive) proc:\(processedCount) drop:\(droppedCount) rotateDrop:\(consecutiveDropCount) gpu:\(hasGpuRotator ? "Y" : "N") gpuDead:\(gpuPermanentFailure) \(commandStats.summary)"
    }
}

actor FrameProcessorActor {
    private var gpuRotator: RPVideoRotatorNV12BatchQueueOptimized?
    private var cpuRotator: RPVideoRotatorCPU_NV12?
    private var lastKey: (useBic: Bool, dstW: Int, dstH: Int, outW: Int, outH: Int, rotateOriginal: Bool)?
    private let sendlog: (String) -> Void
    private var debug: Bool
    private var onPermanentFailure: (@Sendable () -> Void)?

    private var consecutiveDropCount = 0
    private let fallbackFreezeThreshold = 3
    private let maxConsecutiveDrops = 60
    private var lastGoodSnapshot: CVPixelBuffer?
    private var lastGoodFormatDescription: CMVideoFormatDescription?
    private var lastInputPTS: CMTime?
    private var measuredInterval: CMTime?

    init(debug: Bool, sendlog: @escaping (String) -> Void) {
        self.debug = debug
        self.sendlog = sendlog
    }

    nonisolated func setPermanentFailureHandler(_ handler: @Sendable @escaping () -> Void) {
        Task { await _setPermanentFailureHandler(handler) }
    }

    private func _setPermanentFailureHandler(_ handler: @Sendable @escaping () -> Void) {
        onPermanentFailure = handler
    }

    func processFrame(
        imageBuffer: CVImageBuffer,
        originalTime: CMSampleTimingInfo,
        angle: RotationAngle
    ) async -> CMSampleBuffer? {
        let result: CMSampleBuffer?
        if let rotator = await getOrCreateGpuRotator() {
            if rotator.isPermanentlyDead {
                onPermanentFailure?()
                result = await tryCpuFallback(imageBuffer: imageBuffer, originalTime: originalTime, angle: angle)
            } else {
                result = await rotator.rotateAsync(pixelBuffer: imageBuffer, originalTime: originalTime, angle: angle)
            }
        } else {
            result = await tryCpuFallback(imageBuffer: imageBuffer, originalTime: originalTime, angle: angle)
        }
        trackFrameInterval(pts: originalTime.presentationTimeStamp)
        return settle(result, originalTime: originalTime)
    }

    // 量測輸入幀的實際 PTS 間隔（EMA），供 freeze fallback 在 duration 無效時使用，
    // 取代硬編碼的 1/60（60fps 假設）。freeze 期間 ReplayKit 幀仍以真實幀率送達，
    // 因此量測值能自動適應 30/60fps。
    private func trackFrameInterval(pts: CMTime) {
        if let last = lastInputPTS {
            let delta = pts - last
            if delta.isValid, delta.seconds > 0 {
                let alpha = 0.2
                if let m = measuredInterval {
                    measuredInterval = CMTime(
                        seconds: m.seconds * (1 - alpha) + delta.seconds * alpha,
                        preferredTimescale: 600
                    )
                } else {
                    measuredInterval = delta
                }
            }
        }
        lastInputPTS = pts
    }

    private func settle(_ result: CMSampleBuffer?, originalTime: CMSampleTimingInfo) -> CMSampleBuffer? {
        guard let result else {
            consecutiveDropCount += 1
            if consecutiveDropCount == fallbackFreezeThreshold {
                sendlog("[VProc] ⚠️ 旋轉連續失敗 \(consecutiveDropCount) 幀，啟用最後好幀 freeze 保持下游 video")
            } else if consecutiveDropCount > fallbackFreezeThreshold, consecutiveDropCount % 60 == 0 {
                sendlog("[VProc] ⚠️ 旋轉仍失敗 \(consecutiveDropCount) 幀，持續 freeze fallback")
            }
            if consecutiveDropCount >= maxConsecutiveDrops {
                sendlog("[VProc] ❌ 連續 \(consecutiveDropCount) 幀旋轉失敗，標記重建")
                lastGoodSnapshot = nil
                lastGoodFormatDescription = nil
                onPermanentFailure?()
                return nil
            }
            guard consecutiveDropCount >= fallbackFreezeThreshold else { return nil }
            return makeFallbackSampleBuffer(pts: originalTime.presentationTimeStamp, originalTime: originalTime)
        }

        consecutiveDropCount = 0
        storeLastGoodSnapshot(from: result)
        return result
    }

    private func storeLastGoodSnapshot(from sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = sampleBuffer.imageBuffer,
              let copied = copyPixelBuffer(imageBuffer) else {
            return
        }
        lastGoodSnapshot = copied
        lastGoodFormatDescription = sampleBuffer.formatDescription
    }

    private func makeFallbackSampleBuffer(
        pts: CMTime,
        originalTime: CMSampleTimingInfo
    ) -> CMSampleBuffer? {
        guard let snapshot = lastGoodSnapshot else { return nil }

        let duration: CMTime
        if originalTime.duration.isValid, originalTime.duration.seconds > 0 {
            duration = originalTime.duration
        } else if let measuredInterval {
            duration = measuredInterval
        } else {
            duration = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        let formatDescription: CMVideoFormatDescription
        if let lastGoodFormatDescription {
            formatDescription = lastGoodFormatDescription
        } else {
            var createdFormat: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: snapshot,
                formatDescriptionOut: &createdFormat
            )
            guard status == noErr, let createdFormat else {
                sendlog("[VProc] ⚠️ fallback format 建立失敗 status:\(status)")
                return nil
            }
            formatDescription = createdFormat
            lastGoodFormatDescription = createdFormat
        }

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: snapshot,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else {
            sendlog("[VProc] ⚠️ fallback sample 建立失敗 status:\(status)")
            return nil
        }
        return sampleBuffer
    }

    private func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var copied: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attrs as CFDictionary,
            &copied
        )
        guard createStatus == kCVReturnSuccess, let copied else {
            sendlog("[VProc] ⚠️ fallback snapshot 建立失敗 status:\(createStatus)")
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copied, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copied, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        if CVPixelBufferGetPlaneCount(source) > 0 {
            for plane in 0..<CVPixelBufferGetPlaneCount(source) {
                guard let srcBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dstBase = CVPixelBufferGetBaseAddressOfPlane(copied, plane) else {
                    return nil
                }
                let srcStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let dstStride = CVPixelBufferGetBytesPerRowOfPlane(copied, plane)
                let planeHeight = CVPixelBufferGetHeightOfPlane(source, plane)
                let bytesPerRow = min(srcStride, dstStride)

                for row in 0..<planeHeight {
                    memcpy(
                        dstBase.advanced(by: row * dstStride),
                        srcBase.advanced(by: row * srcStride),
                        bytesPerRow
                    )
                }
            }
        } else {
            guard let srcBase = CVPixelBufferGetBaseAddress(source),
                  let dstBase = CVPixelBufferGetBaseAddress(copied) else {
                return nil
            }
            let srcStride = CVPixelBufferGetBytesPerRow(source)
            let dstStride = CVPixelBufferGetBytesPerRow(copied)
            let bytesPerRow = min(srcStride, dstStride)

            for row in 0..<height {
                memcpy(
                    dstBase.advanced(by: row * dstStride),
                    srcBase.advanced(by: row * srcStride),
                    bytesPerRow
                )
            }
        }

        return copied
    }

    private func getOrCreateGpuRotator() async -> RPVideoRotatorNV12BatchQueueOptimized? {
        let key = (
            useBic: RPConfig.shared.state.useBic,
            dstW: RPConfig.shared.state.ADWidth,
            dstH: RPConfig.shared.state.ADHeight,
            outW: RPConfig.shared.state.ODWidth,
            outH: RPConfig.shared.state.ODHeight,
            rotateOriginal: RPConfig.shared.state.RotateOriginal
        )
        if let r = gpuRotator, let last = lastKey, last == key {
            return r
        }
        await gpuRotator?.cleanup()
        lastKey = key
        gpuRotator = RPVideoRotatorNV12BatchQueueOptimized(
            dstW: key.dstW, dstH: key.dstH,
            outW: key.outW, outH: key.outH,
            debug: debug,
            useBic: key.useBic ? .quality : .live,
            RotateOriginal: key.rotateOriginal
        )
        return gpuRotator
    }

    private func tryCpuFallback(
        imageBuffer: CVImageBuffer,
        originalTime: CMSampleTimingInfo,
        angle: RotationAngle
    ) async -> CMSampleBuffer? {
        if cpuRotator == nil {
            cpuRotator = RPVideoRotatorCPU_NV12()
            cpuRotator?.OutWW = RPConfig.shared.state.ODWidth
            cpuRotator?.OutHH = RPConfig.shared.state.ODHeight
            cpuRotator?.debug = debug
        }
        guard let sb = wrapAsSampleBuffer(imageBuffer: imageBuffer, originalTime: originalTime),
              let cpuRotator else { return nil }
        return await cpuRotator.rotateAsync(sampleBuffer: sb, angle: angle, needsRotation: true)
    }

    private func wrapAsSampleBuffer(imageBuffer: CVImageBuffer, originalTime: CMSampleTimingInfo) -> CMSampleBuffer? {
        var formatDesc: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &formatDesc
        ) == noErr, let fmt = formatDesc else { return nil }
        var timing = originalTime
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmt,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }

    func cleanup() async {
        await gpuRotator?.cleanup()
        cpuRotator?.cleanup()
        gpuRotator = nil
        cpuRotator = nil
        consecutiveDropCount = 0
        lastGoodSnapshot = nil
        lastGoodFormatDescription = nil
        lastInputPTS = nil
        measuredInterval = nil
    }

    nonisolated func setRotatorDebug(_ on: Bool) {
        Task { await _setRotatorDebug(on) }
    }

    private func _setRotatorDebug(_ on: Bool) {
        gpuRotator?.debug = on
    }

    nonisolated func setRotatorTsDebug(_ on: Bool) {
        Task { await _setRotatorTsDebug(on) }
    }

    private func _setRotatorTsDebug(_ on: Bool) {
        gpuRotator?.tsDebug(on)
    }

    nonisolated func updateRotatorDimensions(adWidth: Int, adHeight: Int, outWidth: Int, outHeight: Int) {
        Task {
            await _updateRotatorDimensions(
                adWidth: adWidth,
                adHeight: adHeight,
                outWidth: outWidth,
                outHeight: outHeight
            )
        }
    }

    private func _updateRotatorDimensions(adWidth: Int, adHeight: Int, outWidth: Int, outHeight: Int) {
        gpuRotator?.dstWW = adWidth
        gpuRotator?.dstHH = adHeight
        gpuRotator?.OutWW = outWidth
        gpuRotator?.OutHH = outHeight
        cpuRotator?.dstWW = adWidth
        cpuRotator?.dstHH = adHeight
        cpuRotator?.OutWW = outWidth
        cpuRotator?.OutHH = outHeight
        lastKey = nil
    }

    func diagnostics(isActive: Bool, processedCount: Int, droppedCount: Int) -> VideoProcessorDiagnostics {
        VideoProcessorDiagnostics(
            isActive: isActive,
            processedCount: processedCount,
            droppedCount: droppedCount,
            consecutiveDropCount: consecutiveDropCount,
            hasGpuRotator: gpuRotator != nil,
            gpuPermanentFailure: gpuRotator?.isPermanentlyDead ?? false,
            commandStats: gpuRotator?.commandStats() ?? .empty
        )
    }
}

final class VideoFrameProcessor {
    private let mediaMixer: MediaMixer
    private let sendlog: (String) -> Void
    private var actor: FrameProcessorActor
    private var angle: RotationAngle
    private(set) var isActive = true
    private(set) var processedCount = 0
    private(set) var droppedCount = 0

    init(mediaMixer: MediaMixer, sendlog: @escaping (String) -> Void) {
        self.mediaMixer = mediaMixer
        self.sendlog = sendlog
        self.angle = RotationAngle(rawValue: UInt32(RPConfig.shared.state.Rotate)) ?? .landscapeRight
        self.actor = FrameProcessorActor(
            debug: RPConfig.shared.enableRotateLog,
            sendlog: sendlog
        )
        let onFailure: @Sendable () -> Void = { [weak self] in
            self?.isActive = false
            return
        }
        actor.setPermanentFailureHandler(onFailure)
    }

    func process(_ sampleBuffer: CMSampleBuffer, originalTime: CMSampleTimingInfo) {
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        if processedCount % 1500 == 0 || processedCount == 60 {
            let fmt = CVPixelBufferGetPixelFormatType(imageBuffer)
            let fmtStr: String
            switch fmt {
            case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: fmtStr = "NV12"
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: fmtStr = "NV12_video"
            case kCVPixelFormatType_32BGRA: fmtStr = "BGRA"
            case kCVPixelFormatType_32ARGB: fmtStr = "ARGB"
            default: fmtStr = "other(\(String(format: "0x%08x", fmt)))"
            }
            sendlog("[VFormat] #\(processedCount) fmt=\(fmtStr) \(CVPixelBufferGetWidth(imageBuffer))x\(CVPixelBufferGetHeight(imageBuffer))")
        }
        Task {
            guard let rotated = await actor.processFrame(imageBuffer: imageBuffer, originalTime: originalTime, angle: angle) else {
                droppedCount &+= 1
                if droppedCount % 300 == 0 {
                    sendlog("[VProc] ⚠️ 已累積 drop \(droppedCount) 幀 (proc: \(processedCount))")
                }
                return
            }
            processedCount &+= 1
            guard await mediaMixer.isRunning else {
                if processedCount % 300 == 0 {
                    sendlog("[VProc] ⚠️ MediaMixer 未運行，丟棄 processed video")
                }
                return
            }
            await mediaMixer.append(rotated)
        }
    }

    func cleanup() {
        isActive = false
        Task { await actor.cleanup() }
    }

    func setRotatorDebug(_ on: Bool) {
        actor.setRotatorDebug(on)
    }

    func setRotatorTsDebug(_ on: Bool) {
        actor.setRotatorTsDebug(on)
    }

    func updateRotatorDimensions(adWidth: Int, adHeight: Int, outWidth: Int, outHeight: Int) {
        actor.updateRotatorDimensions(
            adWidth: adWidth,
            adHeight: adHeight,
            outWidth: outWidth,
            outHeight: outHeight
        )
    }

    func diagnostics() async -> VideoProcessorDiagnostics {
        await actor.diagnostics(
            isActive: isActive,
            processedCount: processedCount,
            droppedCount: droppedCount
        )
    }
}
