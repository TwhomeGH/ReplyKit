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

private func amplifySIMD(_ sampleBuffer: CMSampleBuffer, gain: Float) -> CMSampleBuffer {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return sampleBuffer }

    var length = 0
    var dataPointer: UnsafeMutablePointer<Int8>?

    guard CMBlockBufferGetDataPointer(blockBuffer,
                                      atOffset: 0,
                                      lengthAtOffsetOut: nil,
                                      totalLengthOut: &length,
                                      dataPointerOut: &dataPointer) == noErr,
          let ptr = dataPointer else { return sampleBuffer }

    let sampleCount = length / MemoryLayout<Int16>.size
    let int16Ptr = ptr.withMemoryRebound(to: Int16.self, capacity: sampleCount) { $0 }

    // ⚡ 使用 stack buffer 避免 heap allocation
    let floatSamplesPtr = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
    defer { floatSamplesPtr.deallocate() }

    // 轉換 Int16 -> Float
    vDSP_vflt16(int16Ptr, 1, floatSamplesPtr, 1, vDSP_Length(sampleCount))

    // 放大
    var g = gain
    vDSP_vsmul(floatSamplesPtr, 1, &g, floatSamplesPtr, 1, vDSP_Length(sampleCount))

    // clamp 到 Int16 範圍
    var minVal: Float = Float(Int16.min)
    var maxVal: Float = Float(Int16.max)
    vDSP_vclip(floatSamplesPtr, 1, &minVal, &maxVal, floatSamplesPtr, 1, vDSP_Length(sampleCount))

    // 轉回 Int16
    vDSP_vfix16(floatSamplesPtr, 1, int16Ptr, 1, vDSP_Length(sampleCount))

    return sampleBuffer
}
private func rmsSIMD(from sampleBuffer: CMSampleBuffer) -> Float? {
    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
          CMSampleBufferGetDataBuffer(sampleBuffer) != nil else { return nil }

    let asbd = asbdPointer.pointee
    let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let isInt16 = asbd.mBitsPerChannel == 16

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

        if isFloat {
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
        } else {
            return nil
        }

        totalSamples += sampleCount
    }

    guard totalSamples > 0 else { return nil }

    // 計算 RMS 並標準化到 0…1
    let rms = sqrt(sum / Float(totalSamples))
    let rmsNormalized = isInt16 ? rms / Float(Int16.max) : rms
    return min(max(rmsNormalized, 0.0), 1.0)
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
    private let queue = DispatchQueue(label: "com.liveapp.volumeNotifier")

    var isActive = true

    func cleanup() {
        queue.async {
            self.isActive = false
        }

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
        if now - lastSendTime >= minInterval {
            lastSendTime = now
            queue.async { [weak self, pendingAppVolume, pendingMicVolume] in
                guard let self = self, self.isActive else { return }


                if RPConfig.shared.enableSocketLog {
                    SocketClient.shared
                        .sendSettings(
                            key: "appVolumeLive",
                            value: pendingAppVolume
                        )
                    SocketClient.shared
                        .sendSettings(
                            key: "micVolumeLive",
                            value: pendingMicVolume
                        )

                } else {
                    SharedDefaults.group?.set(pendingAppVolume, forKey: "appVolumeLive")
                    SharedDefaults.group?.set(pendingMicVolume, forKey: "micVolumeLive")

                }

                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("LiveVolumeUpdated" as CFString),
                    nil, nil, true
                )
            }
        }
    }
}


// MARK: UI 百分比 (0~1) → 真實音量 (0~1)，曲線控制低音量更細膩
func percentageToVolume(_ percentage: Double) -> Double {
    let clamped = max(0, min(1, percentage))

    // 指數曲線 exponent < 1 → 前段變化慢，後段變化快
    let exponent: Double = 2.5
    return pow(clamped, exponent)
}

// MARK: 真實音量 (0~1) → UI 百分比 (0~1)
func volumeToPercentage(_ volume: Double) -> Double {
    let clamped = max(0, min(1, volume))
    let exponent: Double = 2.5
    return pow(clamped, 1.0 / exponent)
}


// MARK: 專用管線
actor AudioPipeline {

    private let mediaMixer: MediaMixer

    private var queue: [(CMSampleBuffer, AudioTrackType)] = []
    private var isRunning = false

    init(mediaMixer: MediaMixer) {
        self.mediaMixer = mediaMixer
    }

    func enqueue(_ buffer: CMSampleBuffer, track: AudioTrackType) {
        queue.append((buffer, track))

        if !isRunning {
            isRunning = true
            Task {
                await processLoop()
            }
        }
    }

    private func processLoop() async {
        while !queue.isEmpty {
            let (buffer, track) = queue.removeFirst()
            await processFrame(buffer, track: track)
        }
        isRunning = false
    }

    private func processFrame(
        _ buffer: CMSampleBuffer,
        track: AudioTrackType
    ) async {

        // 直接 append（音訊不能丟）
        await mediaMixer.append(buffer, track: track.rawValue)
    }
}

// MARK: 音頻線程

final class AudioProcessor : @unchecked Sendable {

    // MARK: Buffer
   
    private let mediaMixer: MediaMixer
    private var volumeNotifier: VolumeNotifier
    private let queue = DispatchQueue(
        label: "audio.processor.queue",
        qos: .utility
    )

    private lazy var pipeline = AudioPipeline(mediaMixer: mediaMixer)

    var isActive = true

    //音訊PTS校正用
    private var audioStartPTS: CMTime?
    private var currentPTS: CMTime = .zero
    private let hostClock = CMClockGetHostTimeClock()

    private var lastVideoPTS: CMTime?
    private var lastAudioPTS: CMTime?
    
    private var appAddVolume: Float
    private var micAddVolume: Float
    private var appVolume: Float
    private var micVolume: Float
    private var onAudioPage: Bool
    private var lastRMSUpdateTime: CFTimeInterval = 0

    var rmsInterval: CFTimeInterval = 0.1

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
        self.isActive = true
    }

    func cleanup() {
        queue.async {
            self.isActive = false
        }
    }
    deinit {
        cleanup()
        sendlog(message:"🧹 AudioProcessor deinit — resources released")
    }



    func updateVideoPTS(_ pts: CMTime) {
         // 🛑 1. 避免時間倒退

    if let last = lastVideoPTS {

        if CMTimeCompare(pts, last) <= 0 {

            return

        }
        // 🛑 2. 過小變化忽略（避免抖動）

    if let last = lastVideoPTS {

        let diff = CMTimeGetSeconds(CMTimeSubtract(pts, last))

        if diff < 0.005 { // 小於 5ms 不更新

            return

        }

        }

    }
        
        lastVideoPTS = pts
    }
    
    private func retimeAudioBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
        return sampleBuffer
    }

    let sampleRate = asbd.mSampleRate
    let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)

    let duration = CMTime(
        value: CMTimeValue(numSamples),
        timescale: CMTimeScale(sampleRate)
    )

    var timing = CMSampleTimingInfo(
        duration: duration,
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
    )

    // 🟢 第一次：對齊系統時間
    if audioStartPTS == nil {
        audioStartPTS = videoPTS
        currentPTS = videoPTS
        lastAudioPTS = videoPTS
    }

    if let videoPTS = lastVideoPTS {
    let drift = CMTimeSubtract(currentPTS, videoPTS)
    let driftSeconds = CMTimeGetSeconds(drift)

    if abs(driftSeconds) > 0.1 { //100ms
   
        let adjustSeconds = -driftSeconds * 0.1
        let adjust = CMTime(seconds: adjustSeconds, preferredTimescale: 1000)
       
        currentPTS = CMTimeAdd(currentPTS, adjust)

        if let last = lastAudioPTS {
            if CMTimeCompare(currentPTS, last) <= 0 {
                currentPTS = CMTimeAdd(last, CMTime(value: 1, timescale: 1000)) // +1ms
            }
        }

        
    
        sendlog(message: "音訊偏移 \(driftSeconds)s，已修正")
       
     }
    }
        

    timing.presentationTimeStamp = currentPTS
        
    // 👉 累加（關鍵）
    currentPTS = CMTimeAdd(currentPTS, duration)
    lastAudioPTS = currentPTS

    var newBuffer: CMSampleBuffer?
    CMSampleBufferCreateCopyWithNewTiming(
        allocator: kCFAllocatorDefault,
        sampleBuffer: sampleBuffer,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleBufferOut: &newBuffer
    )

    return newBuffer ?? sampleBuffer
}
    
    func updateVolumes(
        appAdd: Float? = nil,
        micAdd: Float? = nil,
        app: Float? = nil,
        mic: Float? = nil
    ) {
        if let appAdd = appAdd { self.appAddVolume = appAdd }
        if let micAdd = micAdd { self.micAddVolume = micAdd }
        if let app = app { self.appVolume = app }
        if let mic = mic { self.micVolume = mic }
    }

    func updatePage(status: Bool = false) {
        self.onAudioPage = status
    }

    // MARK: 增益
    private func applyGain(
        _ buffer: CMSampleBuffer,
        trackType: AudioTrackType
    ) -> CMSampleBuffer {

        let gain = (trackType == .app) ? self.appAddVolume : self.micAddVolume
        let safeGain = gain.isFinite ? gain : 1.0

        if safeGain > 1.0 {
            return amplifySIMD(buffer, gain: safeGain)
        }

        return buffer
    }


    // MARK: 音量統計
    private func processRMS(_ buffer: CMSampleBuffer, trackType: AudioTrackType) {

        let now = CACurrentMediaTime()

        if self.onAudioPage, now - self.lastRMSUpdateTime > self.rmsInterval {
            self.lastRMSUpdateTime = now

            if let rms = rmsSIMD(from: buffer) {

                let userVolume = (trackType == .app) ? self.appVolume : self.micVolume
                let safeUserVolume = userVolume.isFinite ? userVolume : 1.0

                var adjustedRMS = rms * safeUserVolume
                if !adjustedRMS.isFinite { adjustedRMS = 0 }

                self.volumeNotifier.updateVolume(
                    volume: adjustedRMS,
                    track: Int(trackType.rawValue)
                )
            }
        }
    }





    func enqueue(_ sampleBuffer: CMSampleBuffer, trackType: AudioTrackType) {
        guard isActive else { return }

        // 1️⃣ 做增益
        let amplified = applyGain(sampleBuffer, trackType: trackType)


        //時間戳校正
        let retimed = retimeAudioBuffer(amplified)
        
        // 音量計算還是可以同步做（很快）
        processRMS(retimed, trackType: trackType)

        // 3️⃣ 丟進 AudioPipeline（FIFO，不丟幀）
        Task {
            await pipeline.enqueue(retimed, track: trackType)
        }
    }




}
