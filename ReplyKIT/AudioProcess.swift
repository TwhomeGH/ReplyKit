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




/// 從多個噪音 buffer 建立平均 noiseProfile
func buildAverageNoiseProfile(from buffers: [CMSampleBuffer],
                              sampleRate: Float = 44100.0) -> [Float] {
    var accumulated: [Float]? = nil
    var count = 0
    
    for buf in buffers {
        let profile = estimateNoiseProfile(from: buf, sampleRate: sampleRate)
        if accumulated == nil {
            accumulated = profile
        } else {
            vDSP_vadd(accumulated!, 1, profile, 1, &accumulated!, 1, vDSP_Length(profile.count))
        }
        count += 1
    }
    
    // 平均化
    if var acc = accumulated {
        var divisor = Float(count)
        vDSP_vsdiv(acc, 1, &divisor, &acc, 1, vDSP_Length(acc.count))
        return acc
    }
    return []
}



/// 收集指定數量的背景噪音 buffer
/// - 這裡假設你有一個 captureSession 或 audioInput 能提供 CMSampleBuffer
func collectNoiseBuffers(count: Int,
                         capture: () -> CMSampleBuffer?) -> [CMSampleBuffer] {
    var buffers: [CMSampleBuffer] = []
    for _ in 0..<count {
        if let buf = capture() {
            buffers.append(buf)
        }
    }
    return buffers
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

/// 使用 Wiener Filter 進行背景噪音抑制
    
/// 使用 Wiener Filter 進行背景噪音抑制
private func wienerFilter(_ buffer: CMSampleBuffer,
                          sampleRate: Float = 44100.0,
                          noiseProfile: [Float]) -> CMSampleBuffer {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer),
          let formatDesc = CMSampleBufferGetFormatDescription(buffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
        return buffer
    }

    var lengthAtOffset: Int = 0
    var totalLength: Int = 0
    var dataPointer: UnsafeMutablePointer<Int8>?

    let status = CMBlockBufferGetDataPointer(blockBuffer,
                                             atOffset: 0,
                                             lengthAtOffsetOut: &lengthAtOffset,
                                             totalLengthOut: &totalLength,
                                             dataPointerOut: &dataPointer)
    if status != kCMBlockBufferNoErr || dataPointer == nil {
        return buffer
    }

    let sampleCount: Int
    var floatSamples: [Float]

    // 支援 Float32 / Int16 PCM
    if asbd.pointee.mBitsPerChannel == 32 {
        let floatPtr = UnsafeMutablePointer<Float>(OpaquePointer(dataPointer!))
        sampleCount = totalLength / MemoryLayout<Float>.size
        floatSamples = Array(UnsafeBufferPointer(start: floatPtr, count: sampleCount))
    } else if asbd.pointee.mBitsPerChannel == 16 {
        let int16Ptr = UnsafeMutablePointer<Int16>(OpaquePointer(dataPointer!))
        sampleCount = totalLength / MemoryLayout<Int16>.size
        floatSamples = (0..<sampleCount).map { Float(int16Ptr[$0]) / Float(Int16.max) }
    } else {
        return buffer
    }

    // 找最近的 2^n 長度
    let log2n = vDSP_Length(log2(Float(sampleCount)).rounded(.down))
    let fftLength = 1 << log2n

    guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
        return buffer
    }

    var real = [Float](repeating: 0, count: fftLength)
    var imag = [Float](repeating: 0, count: fftLength)

    let copyCount = min(sampleCount, fftLength)
    for i in 0..<copyCount {
        real[i] = floatSamples[i]
    }

    real.withUnsafeMutableBufferPointer { realBuf in
        imag.withUnsafeMutableBufferPointer { imagBuf in
            var splitComplex = DSPSplitComplex(realp: realBuf.baseAddress!,
                                               imagp: imagBuf.baseAddress!)

            // Forward FFT
            vDSP_fft_zip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

            // 計算頻譜能量
            var magnitudes = [Float](repeating: 0, count: fftLength/2)
            vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftLength/2))

            // Wiener Filter 增益
            for i in 0..<magnitudes.count {
                let S = magnitudes[i]
                let N = noiseProfile[i]
                let gain = S / (S + N + 1e-6) // 避免除零
                splitComplex.realp[i] *= gain
                splitComplex.imagp[i] *= gain
            }

            // Inverse FFT
            vDSP_fft_zip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_INVERSE))

            // 正規化
            var scale = Float(1.0 / Float(fftLength))
            for i in 0..<copyCount {
                floatSamples[i] = splitComplex.realp[i] * scale
            }
        }
    }

    vDSP_destroy_fftsetup(fftSetup)

    // 寫回原始 buffer
    if asbd.pointee.mBitsPerChannel == 32 {
        let floatPtr = UnsafeMutablePointer<Float>(OpaquePointer(dataPointer!))
        for i in 0..<copyCount {
            floatPtr[i] = floatSamples[i]
        }
    } else if asbd.pointee.mBitsPerChannel == 16 {
        let int16Ptr = UnsafeMutablePointer<Int16>(OpaquePointer(dataPointer!))
        for i in 0..<copyCount {
            int16Ptr[i] = Int16(clamping: Int(floatSamples[i] * Float(Int16.max)))
        }
    }

    return buffer
}


    
/// 從一個只有背景噪音的 buffer 建立噪音功率譜
func estimateNoiseProfile(from buffer: CMSampleBuffer,
                          sampleRate: Float = 44100.0) -> [Float] {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer),
          let formatDesc = CMSampleBufferGetFormatDescription(buffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
        return []
    }

    var lengthAtOffset: Int = 0
    var totalLength: Int = 0
    var dataPointer: UnsafeMutablePointer<Int8>?

    let status = CMBlockBufferGetDataPointer(blockBuffer,
                                             atOffset: 0,
                                             lengthAtOffsetOut: &lengthAtOffset,
                                             totalLengthOut: &totalLength,
                                             dataPointerOut: &dataPointer)
    if status != kCMBlockBufferNoErr || dataPointer == nil {
        return []
    }

    let sampleCount: Int
    var floatSamples: [Float]

    // 支援 Float32 / Int16 PCM
    if asbd.pointee.mBitsPerChannel == 32 {
        let floatPtr = UnsafeMutablePointer<Float>(OpaquePointer(dataPointer!))
        sampleCount = totalLength / MemoryLayout<Float>.size
        floatSamples = Array(UnsafeBufferPointer(start: floatPtr, count: sampleCount))
    } else if asbd.pointee.mBitsPerChannel == 16 {
        let int16Ptr = UnsafeMutablePointer<Int16>(OpaquePointer(dataPointer!))
        sampleCount = totalLength / MemoryLayout<Int16>.size
        floatSamples = (0..<sampleCount).map { Float(int16Ptr[$0]) / Float(Int16.max) }
    } else {
        return []
    }

    // 找最近的 2^n 長度
    let log2n = vDSP_Length(log2(Float(sampleCount)).rounded(.down))
    let fftLength = 1 << log2n

    guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
        return []
    }

    var real = [Float](repeating: 0, count: fftLength)
    var imag = [Float](repeating: 0, count: fftLength)

    let copyCount = min(sampleCount, fftLength)
    for i in 0..<copyCount {
        real[i] = floatSamples[i]
    }

    var magnitudes = [Float](repeating: 0, count: fftLength/2)

    real.withUnsafeMutableBufferPointer { realBuf in
        imag.withUnsafeMutableBufferPointer { imagBuf in
            var splitComplex = DSPSplitComplex(realp: realBuf.baseAddress!,
                                               imagp: imagBuf.baseAddress!)

            // Forward FFT
            vDSP_fft_zip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

            // 計算頻譜能量
            vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftLength/2))
        }
    }

    vDSP_destroy_fftsetup(fftSetup)

    return magnitudes
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


    


    private var noiseBuffers: [CMSampleBuffer] = []
    private let noiseBufferTarget = 10  // 收集 10 個 buffer
    var noiseProfile: [Float]? = nil     


    func enqueue(_ sampleBuffer: CMSampleBuffer, trackType: AudioTrackType,oringinaltime: CMSampleTimingInfo) {

        let res = audioSemaphore.wait(timeout: .now() + .milliseconds(5)) 
        
        if res == .timedOut {
            return
        }
        
        queue.async { [weak self] in
            guard let self = self, self.isActive else { return }
            
        
        // 1️⃣ 做增益
        let amplified = applyGain(sampleBuffer, trackType: trackType)


        var denoised = amplified

        // 2️⃣ 可選的噪聲修正（如果開啟了）
        if RPConfig.shared.enableNoiseFix {

            if self.noiseProfile == nil {
                if self.noiseBuffers.count < self.noiseBufferTarget {
                    self.noiseBuffers.append(sampleBuffer)
                }
                if self.noiseBuffers.count == self.noiseBufferTarget {
                    self.noiseProfile = buildAverageNoiseProfile(from: self.noiseBuffers,
                                                                 sampleRate: 44100)
                    self.noiseBuffers.removeAll()

                    sendlog(message: "Noise profile estimated from \(self.noiseBufferTarget) buffers")
                }
            }

            // 3️⃣ 使用固定 noiseProfile 做 Wiener Filter
            if let profile = self.noiseProfile {
                let processedBuffer = wienerFilter(amplified,
                                                   sampleRate: 44100,
                                                   noiseProfile: profile)
                denoised = processedBuffer
            }


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
