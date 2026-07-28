import HaishinKit
import RTMPHaishinKit
import ReplayKit
import Foundation
import CoreMedia
import CoreVideo
import os

actor FrameProcessorActor {
    private var gpuRotator: RPVideoRotatorNV12BatchQueueOptimized?
    private var cpuRotator: RPVideoRotatorCPU_NV12?
    private var lastKey: (useBic: Bool, dstW: Int, dstH: Int, outW: Int, outH: Int, rotateOriginal: Bool)?
    private let sendlog: (String) -> Void
    private var debug: Bool
    private var onPermanentFailure: (@Sendable () -> Void)?

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
        guard let rotator = await getOrCreateGpuRotator() else {
            return await tryCpuFallback(imageBuffer: imageBuffer, originalTime: originalTime, angle: angle)
        }
        if rotator.isPermanentlyDead {
            onPermanentFailure?()
            return await tryCpuFallback(imageBuffer: imageBuffer, originalTime: originalTime, angle: angle)
        }
        return await rotator.rotateAsync(pixelBuffer: imageBuffer, originalTime: originalTime, angle: angle)
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
        gpuRotator?.cleanup()
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
    }
}

final class VideoFrameProcessor {
    private let mediaMixer: MediaMixer
    private let sendlog: (String) -> Void
    private var actor: FrameProcessorActor
    private var angle: RotationAngle
    private(set) var isActive = true

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
        Task {
            guard let rotated = await actor.processFrame(imageBuffer: imageBuffer, originalTime: originalTime, angle: angle) else { return }
            guard await mediaMixer.isRunning else { return }
            await mediaMixer.append(rotated)
        }
    }

    func cleanup() {
        isActive = false
        Task { await actor.cleanup() }
    }
}
