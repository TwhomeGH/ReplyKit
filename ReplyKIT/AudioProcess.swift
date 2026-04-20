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

final class AudioProcessor : @unchecked Sendable {

    // MARK: Buffer
    
    private let mediaMixer: MediaMixer
    private var volumeNotifier: VolumeNotifier
    private let queue = DispatchQueue(
        label: "audio.processor.queue"
    )

    private let audioSemaphore = DispatchSemaphore(value: 5)

    var isActive = true

    //音訊PTS校正用
    private var audioStartPTS: CMTime?
    private var currentPTS: CMTime = .zero
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



// 將 60Hz 噪聲從音訊中去除（如果有的話），避免干擾音量計算和聽感

private func applyNoiseFixFFT(_ buffer: CMSampleBuffer,
                              targetFrequency: Float = 60.0,
                              sampleRate: Float = 48000.0,
                              bandwidth: Float = 5.0) -> CMSampleBuffer {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { return buffer }

    var length = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    let status = CMBlockBufferGetDataPointer(blockBuffer,
                                             atOffset: 0,
                                             lengthAtOffsetOut: &length,
                                             totalLengthOut: &length,
                                             dataPointerOut: &dataPointer)
    if status != kCMBlockBufferNoErr || dataPointer == nil {
        return buffer
    }

    let floatPtr = UnsafeMutablePointer<Float>(OpaquePointer(dataPointer!))
    let sampleCount = length / MemoryLayout<Float>.size

    // 建立 FFT setup
    let log2n = vDSP_Length(log2(Float(sampleCount)))
    guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
        return buffer
    }

    // 複數向量
    var real = [Float](repeating: 0, count: sampleCount)
    var imag = [Float](repeating: 0, count: sampleCount)
    floatPtr.withMemoryRebound(to: DSPComplex.self, capacity: sampleCount) { complexPtr in
        for i in 0..<sampleCount {
            real[i] = floatPtr[i]
        }
    }

    var splitComplex = DSPSplitComplex(realp: &real, imagp: &imag)

    // Forward FFT
    vDSP_fft_zip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

    // 計算目標頻率對應的 bin
    let bin = Int((targetFrequency / sampleRate) * Float(sampleCount))
    let bwBins = Int((bandwidth / sampleRate) * Float(sampleCount))

    // Notch filter: 把目標頻率附近的 bin 壓低
    for i in max(0, bin - bwBins)...min(sampleCount/2, bin + bwBins) {
        splitComplex.realp[i] = 0
        splitComplex.imagp[i] = 0
    }

    // Inverse FFT
    vDSP_fft_zip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_INVERSE))

    // 正規化
    var scale = Float(1.0 / Float(sampleCount))
    vDSP_vsmul(splitComplex.realp, 1, &scale, floatPtr, 1, vDSP_Length(sampleCount))

    vDSP_destroy_fftsetup(fftSetup)

    return buffer
}
    

private func retimeAudioBuffer(_ sampleBuffer: CMSampleBuffer, originalTime: CMSampleTimingInfo) -> CMSampleBuffer {

    if audioStartPTS == nil {
        audioStartPTS = originalTime.presentationTimeStamp
        sendlog(message: "Audio PTS before retiming: \(originalTime.presentationTimeStamp.seconds)")
    }

    var newBuffer: CMSampleBuffer?
    var timingInfo = originalTime
    
    
    let status = CMSampleBufferCreateCopyWithNewTiming(
    allocator: kCFAllocatorDefault,
    sampleBuffer: sampleBuffer,
    sampleTimingEntryCount: 1,
    sampleTimingArray: &timingInfo,
    sampleBufferOut: &newBuffer
    )

    if status == noErr, let buffer = newBuffer {
        return buffer
    } else {
        return sampleBuffer
    }


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





    func enqueue(_ sampleBuffer: CMSampleBuffer, trackType: AudioTrackType,oringinaltime: CMSampleTimingInfo) {

        let res = audioSemaphore.wait(timeout: .now() + .milliseconds(5)) 
        
        if res == .timedOut {
            return
        }
        
        queue.async { [weak self] in
            guard let self = self, self.isActive else { return }
            
        
        // 1️⃣ 做增益
        let amplified = applyGain(sampleBuffer, trackType: trackType)


        let denoised = amplified
        
        // 2️⃣ 可選的噪聲修正（如果開啟了）
        if RPConfig.shared.enableNoiseFix {
        // 做音訊處理（例如去除 60Hz 噪聲）
        let denoised  = applyNoiseFixFFT(amplified, targetFrequency: 60.0, sampleRate: 48000.0)

        }  

        //時間戳校正
        let retimed = retimeAudioBuffer(denoised, originalTime: oringinaltime)
        
        // 音量計算還是可以同步做（很快）
        processRMS(retimed, trackType: trackType)

        // 3️⃣ 丟進 AudioPipeline（FIFO，不丟幀）
        Task {

            defer { self.audioSemaphore.signal() }

            // 直接 append（音訊不能丟）
            await self.mediaMixer.append(sampleBuffer, track: trackType.rawValue)
        }

        }
    }




}
