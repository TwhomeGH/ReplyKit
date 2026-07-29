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

// MARK: 音量統計

private func rmsSIMD(from sampleBuffer: CMSampleBuffer) -> Float? {
    guard let pcmBuffer = toPCMBuffer(sampleBuffer) else {
        sendlog(message: "[RMS] toPCMBuffer failed")
        return nil
    }
    guard let chData = pcmBuffer.floatChannelData else {
        sendlog(message: "[RMS] no floatChannelData")
        return nil
    }
    let frameCount = Int(pcmBuffer.frameLength)
    guard frameCount > 0 else {
        sendlog(message: "[RMS] frameCount=0")
        return nil
    }
    var meanSquare: Float = 0
    vDSP_measqv(chData[0], 1, &meanSquare, vDSP_Length(frameCount))
    let rms = sqrt(meanSquare)
    return min(max(rms, 0.0), 1.0)
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

    func updateVolume(app: Float, mic: Float) {
        guard isActive else {
            sendlog(message: "[Volume] updateVolume skipped: isActive=false")
            return
        }
        sendlog(message: "[Volume] app=\(app) mic=\(mic)")
        SocketClient.shared.latestAppVolume = app
        SocketClient.shared.latestMicVolume = mic
        SocketClient.shared.flushVolumeBatch()
        if !RPConfig.isSideload {
            SharedDefaults.group?.set(app, forKey: "appVolumeLive")
            SharedDefaults.group?.set(mic, forKey: "micVolumeLive")
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
    private var lastRMSUpdateTime: CFTimeInterval = 0
    var rmsInterval: CFTimeInterval = 1.0
    private var streamTask: Task<Void, Never>?
    private var lastAppRMS: Float = 0
    private var lastMicRMS: Float = 0

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
        streamTask = Task { [weak self] in
            for await item in stream {
                guard let self = self else { break }
                guard await mediaMixer.isRunning else { continue }
                await processRMS(item.buffer, trackType: item.trackType, originalTime: item.originalTime)
                await mediaMixer.append(item.buffer, track: item.trackType.rawValue)
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
        guard onAudioPage || RPConfig.shared.onAudioPage, now - lastRMSUpdateTime > rmsInterval else { return }
        lastRMSUpdateTime = now
        if let rms = rmsSIMD(from: buffer) {
            let userVolume = (trackType == .app) ? appVolume : micVolume
            let normalized = rms * userVolume
            sendlog(message: "[RMS] \(trackType) raw=\(rms) vol=\(userVolume) norm=\(normalized)")
            if trackType == .app {
                lastAppRMS = normalized
            } else {
                lastMicRMS = normalized
            }
            volumeNotifier.updateVolume(app: lastAppRMS, mic: lastMicRMS)
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
