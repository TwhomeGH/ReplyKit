//
//  AudioProcess.swift
//  liveAPP
//
//  Created by user on 2025/10/13.
//



import Foundation
import AVFoundation
import Accelerate
import HaishinKit
import os



enum AudioTrackType: UInt8 {
    case app = 0
    case mic = 1
}


// 將 CMSampleBuffer 轉換成 AVAudioPCMBuffer
func toPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
        return nil
    }
    guard let format = AVAudioFormat(streamDescription: asbd) else { return nil }
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
    
    var length = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
            let ptr = dataPointer else { return nil }
    
    let frameCapacity = length / Int(asbd.pointee.mBytesPerFrame)
    guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCapacity)) else {
        return nil
    }
    pcmBuffer.frameLength = pcmBuffer.frameCapacity
    
    // copy raw data into pcmBuffer
    memcpy(pcmBuffer.int16ChannelData![0], ptr, length)
    return pcmBuffer
}

// MARK: 音量統計

private func rmsSIMD(from sampleBuffer: CMSampleBuffer) -> Float? {
    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
        sendlog(message: "[RMS] missing format description")
        return nil
    }

    let asbd = asbdPointer.pointee
    guard asbd.mFormatID == kAudioFormatLinearPCM else {
        sendlog(message: "[RMS] unsupported formatID=\(asbd.mFormatID)")
        return nil
    }

    var bufferListSize = 0
    var sizingBlockBuffer: CMBlockBuffer?
    let sizingStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: &bufferListSize,
        bufferListOut: nil,
        bufferListSize: 0,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        blockBufferOut: &sizingBlockBuffer
    )
    guard sizingStatus == noErr, bufferListSize > 0 else {
        sendlog(message: "[RMS] bufferList sizing failed status=\(sizingStatus)")
        return nil
    }

    let rawBufferList = UnsafeMutableRawPointer.allocate(
        byteCount: bufferListSize,
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawBufferList.deallocate() }

    var retainedBlockBuffer: CMBlockBuffer?
    let fillStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: nil,
        bufferListOut: rawBufferList.assumingMemoryBound(to: AudioBufferList.self),
        bufferListSize: bufferListSize,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        blockBufferOut: &retainedBlockBuffer
    )
    guard fillStatus == noErr else {
        sendlog(message: "[RMS] bufferList fill failed status=\(fillStatus)")
        return nil
    }

    let audioBuffers = UnsafeMutableAudioBufferListPointer(
        rawBufferList.assumingMemoryBound(to: AudioBufferList.self)
    )
    let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let isSignedInteger = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
    let bytesPerSample = max(Int(asbd.mBitsPerChannel / 8), 1)
    var weightedMeanSquare: Double = 0
    var totalSamples = 0

    for audioBuffer in audioBuffers {
        guard let data = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { continue }
        let sampleCount = Int(audioBuffer.mDataByteSize) / bytesPerSample
        guard sampleCount > 0 else { continue }

        switch (isFloat, isSignedInteger, asbd.mBitsPerChannel) {
        case (true, _, 32):
            let samples = data.bindMemory(to: Float.self, capacity: sampleCount)
            var meanSquare: Float = 0
            vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(sampleCount))
            weightedMeanSquare += Double(meanSquare) * Double(sampleCount)

        case (true, _, 64):
            let samples = data.bindMemory(to: Double.self, capacity: sampleCount)
            var meanSquare: Double = 0
            vDSP_measqvD(samples, 1, &meanSquare, vDSP_Length(sampleCount))
            weightedMeanSquare += meanSquare * Double(sampleCount)

        case (false, true, 16):
            let samples = data.bindMemory(to: Int16.self, capacity: sampleCount)
            var floatSamples = [Float](repeating: 0, count: sampleCount)
            vDSP_vflt16(samples, 1, &floatSamples, 1, vDSP_Length(sampleCount))
            var meanSquare: Float = 0
            vDSP_measqv(floatSamples, 1, &meanSquare, vDSP_Length(sampleCount))
            weightedMeanSquare += Double(meanSquare) * Double(sampleCount)

        case (false, true, 32):
            let samples = data.bindMemory(to: Int32.self, capacity: sampleCount)
            var floatSamples = [Float](repeating: 0, count: sampleCount)
            vDSP_vflt32(samples, 1, &floatSamples, 1, vDSP_Length(sampleCount))
            var meanSquare: Float = 0
            vDSP_measqv(floatSamples, 1, &meanSquare, vDSP_Length(sampleCount))
            weightedMeanSquare += Double(meanSquare) * Double(sampleCount)

        default:
            sendlog(message: "[RMS] unsupported PCM bits=\(asbd.mBitsPerChannel) flags=\(asbd.mFormatFlags)")
            return nil
        }

        totalSamples += sampleCount
    }

    guard totalSamples > 0 else {
        sendlog(message: "[RMS] sampleCount=0")
        return nil
    }

    var rms = sqrt(weightedMeanSquare / Double(totalSamples))
    if !isFloat {
        let peak = pow(2.0, Double(asbd.mBitsPerChannel - 1)) - 1.0
        rms /= peak
    }

    guard rms.isFinite else {
        sendlog(message: "[RMS] non-finite rms")
        return nil
    }

    return Float(min(max(rms, 0.0), 1.0))
}


// MARK: PCM音頻格式 
func pcmBitrate(from sampleBuffer: CMSampleBuffer) -> [String:Any] {
    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
        return [
            "HZ": 48,
            "Channel":1,
            "BitRate": 12800
        ]
    }

    // 位元率 = 取樣率 * 每樣本位元數 * 聲道數
    let bitRate = Int(asbd.mSampleRate * Double(asbd.mBitsPerChannel * asbd.mChannelsPerFrame))
    return [
        "HZ": asbd.mBitsPerChannel,
        "Channel":asbd.mChannelsPerFrame,
        "BitRate": bitRate
    ]

}


// MARK: 音量更新
final class VolumeNotifier {
    var isActive = true

    func cleanup() {
        self.isActive = false
    }

    deinit {
        cleanup()
        sendlog(message: "Audio實時更新清理")
    }

    func updateVolume(app: Float? = nil, mic: Float? = nil) {
        guard isActive else {
            sendlog(message: "[Volume] updateVolume skipped: isActive=false")
            return
        }
        guard app != nil || mic != nil else { return }
        var changed = false
        if let app = app {
            SocketClient.shared.latestAppVolume = app
            SocketClient.shared.updateVolumeTimestamp()
            if !RPConfig.isSideload {
                SharedDefaults.group?.set(app, forKey: "appVolumeLive")
            }
            changed = true
        }
        if let mic = mic {
            SocketClient.shared.latestMicVolume = mic
            SocketClient.shared.updateVolumeTimestamp()
            if !RPConfig.isSideload {
                SharedDefaults.group?.set(mic, forKey: "micVolumeLive")
            }
            changed = true
        }
        guard changed else { return }
        sendlog(message: "[Volume] app=\(SocketClient.shared.latestAppVolume) mic=\(SocketClient.shared.latestMicVolume)")
        SocketClient.shared.flushVolumeBatch()
        if !RPConfig.isSideload {
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("LiveVolumeUpdated" as CFString),
                nil, nil, true
            )
        }
    }
}


// MARK: UI 百分比 (0~1) → 真實音量 (0~1)，曲線控制低音量更細膩
func percentageToVolume(_ percentage: Double) -> Double {
    let clamped = max(0, min(1, percentage))

    // 指數曲線 exponent < 1 → 前段變化慢，後段變化快
    let exponent: Double = 0.5
    return pow(clamped, exponent)
}

// MARK: 真實音量 (0~1) → UI 百分比 (0~1)
func volumeToPercentage(_ volume: Double) -> Double {
    let clamped = max(0, min(1, volume))
    let exponent: Double = 0.5
    return pow(clamped, 1.0 / exponent)
}



// MARK: 音頻線程

actor AudioProcessorActor {
    private let mediaMixer: MediaMixer
    private var volumeNotifier: VolumeNotifier
    private var audioEngine: AudioEngine?
    private var useOriginal: Bool
    private var appAddVolume: Float
    private var micAddVolume: Float
    private var appVolume: Float
    private var micVolume: Float
    private var onAudioPage: Bool
    var rmsInterval: CFTimeInterval = 1.0
    private var streamTask: Task<Void, Never>?
    private var lastAppRMS: Float = 0
    private var lastMicRMS: Float = 0
    private var lastAppRMSUpdateTime: CFTimeInterval = 0
    private var lastMicRMSUpdateTime: CFTimeInterval = 0

    init(mediaMixer: MediaMixer,
         volumeNotifier: VolumeNotifier,
         appAddVolume: Float,
         micAddVolume: Float,
         appVolume: Float,
         micVolume: Float,
         onAudioPage: Bool) {
        self.mediaMixer = mediaMixer
        self.volumeNotifier = volumeNotifier
        self.appAddVolume = appAddVolume
        self.micAddVolume = micAddVolume
        self.appVolume = appVolume
        self.micVolume = micVolume
        self.onAudioPage = onAudioPage
        self.useOriginal = RPConfig.shared.state.isOringinAudio

        if !useOriginal {
            let engine = AudioEngine(
                micGain: micAddVolume,
                echoFix: RPConfig.shared.state.enableEchoFix,
                noiseFix: RPConfig.shared.state.enableNoiseFix,
                agcFix: RPConfig.shared.state.enableAGCFix,
                metalAudio: RPConfig.shared.state.enableMetalAudio
            )
            audioEngine = engine
            Task { await setupAudioStream(engine) }
        }
    }

    private func setupAudioStream(_ engine: AudioEngine) {
        let stream = engine.startStream()
        // Consumer 用 Task.detached 脫離 AudioProcessorActor executor，
        // 避免與 producer（enqueue → 同步 DSP）共用同一 executor 互相阻塞。
        // producer 的 yield 與 consumer 的 mediaMixer.append 因此真正並行，
        // 不再「DSP 慢 → consumer 卡 → 節奏斷裂」。
        streamTask = Task.detached { [weak self] in
            for await item in stream {
                guard let self else { break }
                guard await self.mediaMixer.isRunning else { continue }
                await self.processRMS(item.buffer, trackType: item.trackType, originalTime: item.originalTime)
                await self.mediaMixer.append(item.buffer, track: item.trackType.rawValue)
            }
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer, trackType: AudioTrackType, originalTime: CMSampleTimingInfo) async {
        guard await mediaMixer.isRunning else { return }

        if useOriginal {
            let processed = applyGain(sampleBuffer, trackType: trackType, originalTime: originalTime)
            processRMS(processed, trackType: trackType, originalTime: originalTime)
            await mediaMixer.append(processed, track: trackType.rawValue)
        } else {
            audioEngine?.process(sampleBuffer, track: trackType, originalTime: originalTime)
        }
    }



    // 用 vDSP in-place 做增益
    private func applyGainPCM(_ buffer: AVAudioPCMBuffer, gain: Float) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        var g = gain
        vDSP_vsmul(channelData[0], 1, &g, channelData[0], 1, vDSP_Length(frameCount))
        if buffer.format.channelCount > 1 {
            vDSP_vsmul(channelData[1], 1, &g, channelData[1], 1, vDSP_Length(frameCount))
        }
    }

    // 將 AVAudioPCMBuffer 轉回 CMSampleBuffer
    private func pcmBufferToCMSampleBuffer(_ pcmBuffer: AVAudioPCMBuffer,
                                           originalTime: CMSampleTimingInfo) -> CMSampleBuffer? {
        let format = pcmBuffer.format.streamDescription

        var formatDesc: CMAudioFormatDescription?
        let statusFmt = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: format,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard statusFmt == noErr, let fmtDesc = formatDesc else { return nil }

        // 建立 BlockBuffer
        let frameCount = Int(pcmBuffer.frameLength)
        let byteCount = frameCount * Int(format.pointee.mBytesPerFrame)
        var blockBuffer: CMBlockBuffer?
        let statusBB = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: pcmBuffer.int16ChannelData?[0], // 假設 Int16 格式
            blockLength: byteCount,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard statusBB == noErr, let bb = blockBuffer else { return nil }

        // Timing info
        var timing = originalTime
        var sampleBuffer: CMSampleBuffer?
        let statusSB = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmtDesc,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard statusSB == noErr else { return nil }
        return sampleBuffer
    }

    // 完整流程：CMSampleBuffer → PCM → 增益 → CMSampleBuffer
    func applyGain(_ sampleBuffer: CMSampleBuffer,
                   trackType: AudioTrackType,
                   originalTime: CMSampleTimingInfo) -> CMSampleBuffer {
        let gain = (trackType == .app) ? appAddVolume : micAddVolume
        guard gain > 1.0, let pcmBuffer = toPCMBuffer(sampleBuffer) else {
            return sampleBuffer
        }
        applyGainPCM(pcmBuffer, gain: gain)
        return pcmBufferToCMSampleBuffer(pcmBuffer, originalTime: originalTime) ?? sampleBuffer
    }

    private func processRMS(_ buffer: CMSampleBuffer, trackType: AudioTrackType, originalTime: CMSampleTimingInfo) {
        let now = CACurrentMediaTime()
        let lastUpdate = (trackType == .app) ? lastAppRMSUpdateTime : lastMicRMSUpdateTime
        guard onAudioPage && now - lastUpdate > rmsInterval else { return }
        if trackType == .app {
            lastAppRMSUpdateTime = now
        } else {
            lastMicRMSUpdateTime = now
        }
        if let rms = rmsSIMD(from: buffer) {
            let userVolume = (trackType == .app) ? appVolume : micVolume
            let normalized = rms * userVolume
            sendlog(message: "[RMS] \(trackType) raw=\(rms) vol=\(userVolume) norm=\(normalized)")
            if trackType == .app {
                lastAppRMS = normalized
                volumeNotifier.updateVolume(app: normalized)
            } else {
                lastMicRMS = normalized
                volumeNotifier.updateVolume(mic: normalized)
            }
        } else {
            sendlog(message: "[RMS] rmsSIMD returned nil for \(trackType)")
        }
    }

    func cleanup() {
        streamTask?.cancel()
        streamTask = nil
        audioEngine?.cleanup()
        audioEngine = nil
    }

    func updateVolumes(micAdd value: Float) {
        micAddVolume = value
    }

    func updateVolumes(appAdd value: Float) {
        appAddVolume = value
    }

    func updateVolumes(mic value: Float) {
        micVolume = value
    }

    func updateVolumes(app value: Float) {
        appVolume = value
    }

    func updatePage(status: Bool) {
        onAudioPage = status
    }
}





final class AudioProcessor {
    private let actor: AudioProcessorActor
    let isActive = true

    init(mediaMixer: MediaMixer,
         volumeNotifier: VolumeNotifier,
         appAddVolume: Float,
         micAddVolume: Float,
         appVolume: Float,
         micVolume: Float,
         onAudioPage: Bool) {
        actor = AudioProcessorActor(
            mediaMixer: mediaMixer,
            volumeNotifier: volumeNotifier,
            appAddVolume: appAddVolume,
            micAddVolume: micAddVolume,
            appVolume: appVolume,
            micVolume: micVolume,
            onAudioPage: onAudioPage
        )
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer, trackType: AudioTrackType, originalTime: CMSampleTimingInfo) {
        Task { await actor.enqueue(sampleBuffer, trackType: trackType, originalTime: originalTime) }
    }

    func updateVolumes(micAdd value: Float) {
        Task { await actor.updateVolumes(micAdd: value) }
    }

    func updateVolumes(appAdd value: Float) {
        Task { await actor.updateVolumes(appAdd: value) }
    }

    func updateVolumes(mic value: Float) {
        Task { await actor.updateVolumes(mic: value) }
    }

    func updateVolumes(app value: Float) {
        Task { await actor.updateVolumes(app: value) }
    }

    func updatePage(status: Bool) {
        Task { await actor.updatePage(status: status) }
    }

    func cleanup() {
        Task { await actor.cleanup() }
    }
}
