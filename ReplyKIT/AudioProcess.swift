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
    private var gainFloatBuffer: [Float] = []
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
            audioEngine = AudioEngine(
                micGain: micAddVolume,
                echoFix: RPConfig.shared.state.enableEchoFix,
                noiseFix: RPConfig.shared.state.enableNoiseFix,
                agcFix: RPConfig.shared.state.enableAGCFix,
                metalAudio: RPConfig.shared.state.enableMetalAudio
            )
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer, trackType: AudioTrackType, originalTime: CMSampleTimingInfo) async {
        guard await mediaMixer.isRunning else { return }

        if useOriginal {
            let processed = applyGain(sampleBuffer, trackType: trackType)
            processRMS(processed, trackType: trackType, originalTime: originalTime)
            await mediaMixer.append(processed, track: trackType.rawValue)
        } else {
            audioEngine?.process(sampleBuffer, track: trackType)
            processRMS(sampleBuffer, trackType: trackType, originalTime: originalTime)
            await mediaMixer.append(sampleBuffer, track: trackType.rawValue)
        }
    }



    // 原地增益：直接對原始 block buffer 做 int16 → float → 增益 → 寫回，
    // 不重建 CMSampleBuffer（避免 use-after-free 與每幀分配）。
    // 維持 boost-only 語意（gain > 1.0）：addVolume 是放大倍率，
    // 0.0（UserDefaults 死碼預設）不能被當成合法衰減值而消音。
    func applyGain(_ sampleBuffer: CMSampleBuffer, trackType: AudioTrackType) -> CMSampleBuffer {
        let gain = (trackType == .app) ? appAddVolume : micAddVolume
        guard gain > 1.0 else { return sampleBuffer }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return sampleBuffer }
        var ptr: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: nil, dataPointerOut: &ptr)
        guard let rawPtr = ptr else { return sampleBuffer }
        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        let sampleCount = byteCount / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return sampleBuffer }
        ensureGainBufferCapacity(sampleCount)

        let int16Ptr = UnsafeMutableRawPointer(rawPtr).bindMemory(to: Int16.self, capacity: sampleCount)
        var scale: Float = 1.0 / 32768.0
        var g = gain
        var invScale: Float = 32768.0
        vDSP_vflt16(int16Ptr, 1, &gainFloatBuffer, 1, vDSP_Length(sampleCount))
        vDSP_vsmul(gainFloatBuffer, 1, &scale, &gainFloatBuffer, 1, vDSP_Length(sampleCount))
        vDSP_vsmul(gainFloatBuffer, 1, &g, &gainFloatBuffer, 1, vDSP_Length(sampleCount))
        vDSP_vsmul(gainFloatBuffer, 1, &invScale, &gainFloatBuffer, 1, vDSP_Length(sampleCount))
        vDSP_vfix16(gainFloatBuffer, 1, int16Ptr, 1, vDSP_Length(sampleCount))
        return sampleBuffer
    }

    private func ensureGainBufferCapacity(_ count: Int) {
        if gainFloatBuffer.count < count {
            gainFloatBuffer = [Float](repeating: 0, count: count)
        }
    }

    private func processRMS(_ buffer: CMSampleBuffer, trackType: AudioTrackType, originalTime: CMSampleTimingInfo) {
        let now = CACurrentMediaTime()
        let lastUpdate = (trackType == .app) ? lastAppRMSUpdateTime : lastMicRMSUpdateTime
        guard onAudioPage && now - lastUpdate > rmsInterval || now - lastUpdate > 60.0  else { return }
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
        audioEngine?.cleanup()
        audioEngine = nil
    }

    func updateAudioState(micGain: Float? = nil,
                          echoFix: Bool? = nil,
                          noiseFix: Bool? = nil,
                          agcFix: Bool? = nil,
                          metalAudio: Bool? = nil) {
        audioEngine?.updateAudioState(
            micGain: micGain,
            echoFix: echoFix,
            noiseFix: noiseFix,
            agcFix: agcFix,
            metalAudio: metalAudio
        )
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

    func updateAudioState(micGain: Float? = nil,
                          echoFix: Bool? = nil,
                          noiseFix: Bool? = nil,
                          agcFix: Bool? = nil,
                          metalAudio: Bool? = nil) {
        Task {
            await actor.updateAudioState(
                micGain: micGain,
                echoFix: echoFix,
                noiseFix: noiseFix,
                agcFix: agcFix,
                metalAudio: metalAudio
            )
        }
    }

    func cleanup() {
        Task { await actor.cleanup() }
    }
}
