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
          let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
    let asbd = asbdPointer.pointee

    let isFloat32 = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && asbd.mBitsPerChannel == 32
    let isInt16   = asbd.mBitsPerChannel == 16
    let isInt24   = asbd.mBitsPerChannel == 24

    var audioBufferList = AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer())
    var blockBufferOut: CMBlockBuffer?

    guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: nil,
        bufferListOut: &audioBufferList,
        bufferListSize: MemoryLayout<AudioBufferList>.size,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        blockBufferOut: &blockBufferOut
    ) == noErr else { return nil }

    let audioBuffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
    var sum: Float = 0
    var totalSamples: Int = 0

    for buffer in audioBuffers {
        guard let mData = buffer.mData else { continue }
        let sampleCount = Int(buffer.mDataByteSize) / Int(asbd.mBytesPerFrame)

        if isFloat32 {
            let ptr = mData.bindMemory(to: Float.self, capacity: sampleCount)
            var meanSquare: Float = 0
            vDSP_measqv(ptr, 1, &meanSquare, vDSP_Length(sampleCount))
            sum += meanSquare * Float(sampleCount)

        } else if isInt16 {
            let ptr = mData.bindMemory(to: Int16.self, capacity: sampleCount)
            var floatSamples = [Float](repeating: 0, count: sampleCount)
            vDSP_vflt16(ptr, 1, &floatSamples, 1, vDSP_Length(sampleCount))
            var meanSquare: Float = 0
            vDSP_measqv(floatSamples, 1, &meanSquare, vDSP_Length(sampleCount))
            sum += meanSquare * Float(sampleCount)

        } else if isInt24 {
            // 24-bit PCM: 每樣本 3 bytes，轉成 Int32
            let bytePtr = UnsafeRawPointer(mData).bindMemory(to: UInt8.self, capacity: sampleCount * 3)
            var floatSamples = [Float](repeating: 0, count: sampleCount)
            for i in 0..<sampleCount {
                let b0 = Int32(bytePtr[i*3])
                let b1 = Int32(bytePtr[i*3+1])
                let b2 = Int32(bytePtr[i*3+2])
                // 小端序組合成 24-bit signed
                var value = (b2 << 16) | (b1 << 8) | b0
                if value & 0x800000 != 0 { value |= ~0xFFFFFF } // sign extend
                floatSamples[i] = Float(value) / Float(1 << 23) // normalize to [-1,1]
            }
            var meanSquare: Float = 0
            vDSP_measqv(floatSamples, 1, &meanSquare, vDSP_Length(sampleCount))
            sum += meanSquare * Float(sampleCount)

        } else {
            return nil
        }

        totalSamples += sampleCount
    }

    guard totalSamples > 0 else { return nil }
    let rms = sqrt(sum / Float(totalSamples))
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
    private var pendingAppVolume: Float = 0
    private var pendingMicVolume: Float = 0
    private var lastSendTime: TimeInterval = 0
    private let minInterval: TimeInterval = 0.1

    var isActive = true

    func cleanup() {
        self.isActive = false
    }

    deinit {
        cleanup()
        sendlog(message:"Audio實時更新清理")
    }

    func updateVolume(volume: Float, track: Int) {
        switch track {
        case 0: pendingAppVolume = volume
        case 1: pendingMicVolume = volume
        default: return
        }

        let now = CACurrentMediaTime()
        guard now - lastSendTime >= minInterval else { return }
        lastSendTime = now

        let app = pendingAppVolume
        let mic = pendingMicVolume

        if RPConfig.isSideload {
            SocketClient.shared.sendAudioLive(appVol: app, micVol: mic)
        } else {
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

    // 將 CMSampleBuffer 轉換成 AVAudioPCMBuffer
    private func toPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        let format = AVAudioFormat(streamDescription: asbd)
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
        guard let format = pcmBuffer.format.streamDescription else { return nil }

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
        guard onAudioPage, now - lastRMSUpdateTime > rmsInterval else { return }
        lastRMSUpdateTime = now
        if let rms = rmsSIMD(from: buffer) {
            let userVolume = (trackType == .app) ? appVolume : micVolume
            volumeNotifier.updateVolume(volume: rms * userVolume, track: Int(trackType.rawValue))
        }
    }

    func cleanup() {
        audioEngine?.cleanup()
        audioEngine = nil
    }
}





final class AudioProcessor {
    private let actor: AudioProcessorActor

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

    func cleanup() {
        Task { await actor.cleanup() }
    }
}
