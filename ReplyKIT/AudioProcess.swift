//
//  AudioProcess.swift
//  liveAPP
//
//  Created by user on 2025/10/13.
//

//import Foundation
//import AVFoundation
//import CoreAudio
//import HaishinKit
//
//enum AudioTrackType: UInt8 {
//    case app = 0
//    case mic = 1
//}
//
//private func amplify(_ sampleBuffer: CMSampleBuffer, gain: Float) -> CMSampleBuffer {
//    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return sampleBuffer }
//
//    var length = 0
//    var dataPointer: UnsafeMutablePointer<Int8>?
//
//    guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
//          let ptr = dataPointer else { return sampleBuffer }
//
//    let sampleCount = length / MemoryLayout<Int16>.size
//    let int16Ptr = ptr.withMemoryRebound(to: Int16.self, capacity: sampleCount) { $0 }
//
//    for i in 0..<sampleCount {
//        let floatSample = Float(int16Ptr[i]) * gain
//        int16Ptr[i] = Int16(max(min(floatSample, Float(Int16.max)), Float(Int16.min)))
//    }
//
//    return sampleBuffer
//}
//
//
//private func rmsLevel(from sampleBuffer: CMSampleBuffer) -> Float? {
//    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
//          let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
//          CMSampleBufferGetDataBuffer(sampleBuffer) != nil else { return nil }
//
//    let asbd = asbdPointer.pointee
//    let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
//    let isInt16 = asbd.mBitsPerChannel == 16
//
//    var audioBufferList = AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer())
//    var blockBufferOut: CMBlockBuffer?
//
//    guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
//        sampleBuffer,
//        bufferListSizeNeededOut: nil,
//        bufferListOut: &audioBufferList,
//        bufferListSize: MemoryLayout<AudioBufferList>.size,
//        blockBufferAllocator: kCFAllocatorDefault,
//        blockBufferMemoryAllocator: kCFAllocatorDefault,
//        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
//        blockBufferOut: &blockBufferOut
//    ) == noErr else { return nil }
//
//    let audioBuffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
//    var sum: Float = 0
//    var totalSamples = 0
//
//    for buffer in audioBuffers {
//        guard let mData = buffer.mData else { continue }
//        let sampleCount = Int(buffer.mDataByteSize) / Int(asbd.mBytesPerFrame)
//
//        if isFloat {
//            let ptr = mData.bindMemory(to: Float.self, capacity: sampleCount)
//            for i in 0..<sampleCount { sum += ptr[i] * ptr[i] }
//        } else if isInt16 {
//            let ptr = mData.bindMemory(to: Int16.self, capacity: sampleCount)
//            for i in 0..<sampleCount {
//                let sample = Float(ptr[i]) / Float(Int16.max)
//                sum += sample * sample
//            }
//        } else {
//            return nil
//        }
//
//        totalSamples += sampleCount
//    }
//
//    return totalSamples > 0 ? sqrt(sum / Float(totalSamples)) : nil
//}
//
//class VolumeNotifier {
//    private var pendingAppVolume: Float = 0
//    private var pendingMicVolume: Float = 0
//    private var lastSendTime: TimeInterval = 0
//    private let minInterval: TimeInterval = 0.1
//
//    func updateVolume(volume: Float, track: Int) {
//        switch track {
//        case 0:
//            pendingAppVolume = volume
//        case 1:
//            pendingMicVolume = volume
//        default:
//            return
//        }
//
//        let now = CACurrentMediaTime()
//        if now - lastSendTime >= minInterval {
//            sendVolumeToApp()
//            lastSendTime = now
//        }
//    }
//
//    private let queue = DispatchQueue(label: "com.liveapp.volumeNotifier")
//
//
//    private func sendVolumeToApp() {
//        queue.async { [pendingAppVolume, pendingMicVolume] in
//
//            userDefaults?.set(pendingAppVolume, forKey: "appVolumeLive")
//            userDefaults?.set(pendingMicVolume, forKey: "micVolumeLive")
//
//            CFNotificationCenterPostNotification(
//                CFNotificationCenterGetDarwinNotifyCenter(),
//                CFNotificationName("LiveVolumeUpdated" as CFString),
//                nil,
//                nil,
//                true
//            )
//        }
//    }
//}
//
//
//final class AudioProcessor {
//    private let queue = DispatchQueue(label: "audio.processor.queue", qos: .userInitiated)
//    private let mediaMixer: MediaMixer
//    private let volumeNotifier: VolumeNotifier
//
//    private var appAddVolume: Float
//    private var micAddVolume: Float
//    private var appVolume: Float
//    private var micVolume: Float
//    private var onAudioPage: Bool
//    private var lastRMSUpdateTime: CFTimeInterval = 0
//    private let rmsInterval: CFTimeInterval = 0.1
//
//    init(mediaMixer: MediaMixer,
//         volumeNotifier: VolumeNotifier,
//         appAddVolume: Float,
//         micAddVolume: Float,
//         appVolume: Float,
//         micVolume: Float,
//         onAudioPage: Bool) {
//        self.mediaMixer = mediaMixer
//        self.volumeNotifier = volumeNotifier
//        self.appAddVolume = appAddVolume
//        self.micAddVolume = micAddVolume
//        self.appVolume = appVolume
//        self.micVolume = micVolume
//        self.onAudioPage = onAudioPage
//    }
//
//    func updateVolumes(appAdd: Float? = nil, micAdd: Float? = nil, app: Float? = nil, mic: Float? = nil) {
//        if let appAdd = appAdd { self.appAddVolume = appAdd }
//        if let micAdd = micAdd { self.micAddVolume = micAdd }
//        if let app = app { self.appVolume = app }
//        if let mic = mic { self.micVolume = mic }
//    }
//
//    func updatePage(status: Bool?) {
//        self.onAudioPage = status ?? false
//    }
//
//    func enqueue(_ sampleBuffer: CMSampleBuffer, trackType: AudioTrackType) {
//        queue.async { [weak self] in
//            guard let self = self else { return }
//
//            let gain = (trackType == .app) ? self.appAddVolume : self.micAddVolume
//            let amplified = amplify(sampleBuffer, gain: gain)
//
//            let now = CACurrentMediaTime()
//            if self.onAudioPage, now - self.lastRMSUpdateTime > self.rmsInterval {
//                self.lastRMSUpdateTime = now
//                if let rms = rmsLevel(from: amplified) {
//                    let adjusted = rms * ((trackType == .app) ? self.appVolume : self.micVolume)
//                    self.volumeNotifier.updateVolume(volume: adjusted, track: Int(UInt8(trackType.rawValue)))
//                }
//            }
//
//            // 直接在 queue 裡 await，保證順序且不額外 spawn Task
//            Task(priority: .userInitiated) {
//                await self.mediaMixer.append(amplified, track: trackType.rawValue)
//            }
//        }
//    }
//
//    // amplify() 與 rmsLevel() 保持不變
//    // ...
//}
//


import Foundation
import AVFoundation
import Accelerate
import HaishinKit

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
        isActive = false
        // 清空 queue 上未執行的任務
        queue.sync {} // 確保之前的所有 block 都完成
        // Task 目前無法強制取消，確保 isActive 檢查能立即返回
    }

    deinit {
        isActive = false
        // 清空 queue 上未執行的任務
        queue.sync {} // 確保之前的所有 block 都完成
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

                userDefaults?.set(pendingAppVolume, forKey: "appVolumeLive")
                userDefaults?.set(pendingMicVolume, forKey: "micVolumeLive")
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

// MARK: 音頻線程

final class AudioProcessor : @unchecked Sendable {

    // MARK: Buffer
   
    private let mediaMixer: MediaMixer
    private var volumeNotifier: VolumeNotifier
    private let queue = DispatchQueue(label: "audio.processor.queue", qos: .userInitiated)

    var isActive = true

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
        isActive = false
        // 清空 queue 上未執行的任務
        queue.sync {


        } // 確保之前的所有 block 都完成
        // Task 目前無法強制取消，確保 isActive 檢查能立即返回




    }
    deinit {
        cleanup()
        sendlog(message:"🧹 AudioProcessor deinit — resources released")
    }

    func updateVolumes(appAdd: Float? = nil, micAdd: Float? = nil, app: Float? = nil, mic: Float? = nil) {
        if let appAdd = appAdd { self.appAddVolume = appAdd }
        if let micAdd = micAdd { self.micAddVolume = micAdd }
        if let app = app { self.appVolume = app }
        if let mic = mic { self.micVolume = mic }
    }

    func updatePage(status: Bool?) {
        self.onAudioPage = status ?? false
    }


    func enqueue(_ sampleBuffer: CMSampleBuffer, trackType: AudioTrackType) {

        queue.async { [weak self] in
            guard let self = self, self.isActive else { return }



            self.processAudioFrame(sampleBuffer, trackType: trackType)


        }

    }

    private func processAudioFrame(_ buffer: CMSampleBuffer ,trackType: AudioTrackType) {


            let gain = (trackType == .app) ? self.appAddVolume : self.micAddVolume
        let safeGain = gain.isFinite ? gain : 1.0  // 防止 infinity / NaN



            var amplified = buffer

            if safeGain != 1.0 {
                amplified = amplifySIMD(buffer, gain: safeGain)
            }

            let now = CACurrentMediaTime()
            if self.onAudioPage, now - self.lastRMSUpdateTime > self.rmsInterval {
                self.lastRMSUpdateTime = now
                if let rms = rmsSIMD(from: amplified) {

                    let userVolume = (trackType == .app) ? self.appVolume : self.micVolume

                    let safeUserVolume = userVolume.isFinite ? userVolume : 1.0

                    // 4️⃣ 計算最終 RMS
                    var adjustedRMS = rms * safeUserVolume
                    if !adjustedRMS.isFinite { adjustedRMS = 0 }

                    self.volumeNotifier.updateVolume(volume: adjustedRMS, track: Int(trackType.rawValue))
                }
            }

            // 音訊 append


        Task(priority: .userInitiated) { [weak self] in
            guard let self = self, self.isActive else { return }

            await self.mediaMixer.append(amplified, track: trackType.rawValue)

        }





    }

}
