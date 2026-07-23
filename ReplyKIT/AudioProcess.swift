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

final class AudioProcessor : @unchecked Sendable {

    // MARK: Buffer
    
    private let mediaMixer: MediaMixer
    private var volumeNotifier: VolumeNotifier

    private var _isActiveLock = os_unfair_lock()
    private var _isActive = true
    var isActive: Bool {
        get { os_unfair_lock_lock(&_isActiveLock); defer { os_unfair_lock_unlock(&_isActiveLock) }; return _isActive }
        set { os_unfair_lock_lock(&_isActiveLock); _isActive = newValue; os_unfair_lock_unlock(&_isActiveLock) }
    }

    var UseOringin = true

    //音訊PTS校正用
    private var audioStartPTS: CMTime?
    private var lastAudioPTS: CMTime?
    
    private var appAddVolume: Float
    private var micAddVolume: Float
    private var appVolume: Float
    private var micVolume: Float
    private var onAudioPage: Bool
    private var lastRMSUpdateTime: CFTimeInterval = 0

    private var audioEngine: AudioEngine? = nil

    private var _appGainBuffer: [Float] = []
    private var _micGainBuffer: [Float] = []


    var rmsInterval: CFTimeInterval = 1.0
    

    private func updateNoiseFixState() {

        let micGain = RPConfig.shared.state.MicVolumeAdd 
        // 降噪處理
        let noiseFix = RPConfig.shared.state.enableNoiseFix
        // 回音處理
        let EchoFix = RPConfig.shared.state.enableEchoFix
        // 自動增益
        let AGCFix = RPConfig.shared.state.enableAGCFix
        // Metal 音訊
        let metalAudio = RPConfig.shared.state.enableMetalAudio



        sendlog(message: "音訊配置: 降噪:\(noiseFix) 回音處理:\(EchoFix) 自動增益:\(AGCFix) Metal:\(metalAudio)")
        
        audioEngine?.updateAudioState(micGain:Float(micGain),echoFix:EchoFix,noiseFix:noiseFix,agcFix:AGCFix,metalAudio:metalAudio)

        
    }


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

        // 降噪處理
        let noiseFix = RPConfig.shared.state.enableNoiseFix
        // 回音處理
        let EchoFix = RPConfig.shared.state.enableEchoFix
        // 自動增益
        let AGCFix = RPConfig.shared.state.enableAGCFix
        // Metal 音訊
        let metalAudio = RPConfig.shared.state.enableMetalAudio


        if RPConfig.shared.state.isOringinAudio {

            self.UseOringin = true
            sendlog(message: "AudioEngine停用 使用原本的音訊管線")
            

        }  else {

            self.UseOringin = false
            self.audioEngine = AudioEngine(micGain:micAddVolume,echoFix:EchoFix,noiseFix:noiseFix,agcFix:AGCFix,metalAudio:metalAudio)
            sendlog(message: "AudioEngine啟用 使用專用音訊管線 Metal:\(metalAudio)")

            

        }



    }

    func cleanup() {
        
        self.isActive = false

        sendlog(message: "🧹 AudioProcessor deinit — resources released")
    
    }
    deinit {
        cleanup()
        
    }








    private func retimeAudioBuffer(_ sampleBuffer: CMSampleBuffer, originalTime: CMSampleTimingInfo) -> CMSampleBuffer {

        if audioStartPTS == nil {
            audioStartPTS = originalTime.presentationTimeStamp
            sendlog(message: "Audio PTS before retiming: \(originalTime.presentationTimeStamp.seconds)")
        }

        var timingInfo = originalTime
        let newPTS = timingInfo.presentationTimeStamp

        if let last = lastAudioPTS {
            if newPTS < last {
                timingInfo.presentationTimeStamp = last
                let drift = (last - newPTS).seconds
                if drift > 0.5 {
                    sendlog(message: "Audio PTS jumped backward \(drift)s, clamped to last")
                }
            }
        }
        lastAudioPTS = timingInfo.presentationTimeStamp

        var newBuffer: CMSampleBuffer?
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
        if let appAdd = appAdd { 
                self.appAddVolume = appAdd 
                
            }
        if let micAdd = micAdd { 
                self.micAddVolume = micAdd 
                self.audioEngine?.updateAudioState(micGain:micAdd)
            
            }

        if let app = app { self.appVolume = app }
        if let mic = mic { self.micVolume = mic }

    }

    func updatePage(status: Bool = false) {
        self.onAudioPage = status
    }

    // MARK: 舊增益管線
    private func amplifySIMD(_ sampleBuffer: CMSampleBuffer, gain: Float, trackType: AudioTrackType) -> CMSampleBuffer {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return sampleBuffer }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
              let ptr = dataPointer else { return sampleBuffer }
        let sampleCount = length / MemoryLayout<Int16>.size
        let int16Ptr = ptr.withMemoryRebound(to: Int16.self, capacity: sampleCount) { $0 }

        if trackType == .app {
            if _appGainBuffer.count < sampleCount { _appGainBuffer = [Float](repeating: 0, count: sampleCount) }
            _appGainBuffer.withUnsafeMutableBufferPointer { floatSamplesPtr in
                guard let base = floatSamplesPtr.baseAddress else { return }
                vDSP_vflt16(int16Ptr, 1, base, 1, vDSP_Length(sampleCount))
                var g = gain
                vDSP_vsmul(base, 1, &g, base, 1, vDSP_Length(sampleCount))
                var minVal: Float = Float(Int16.min)
                var maxVal: Float = Float(Int16.max)
                vDSP_vclip(base, 1, &minVal, &maxVal, base, 1, vDSP_Length(sampleCount))
                vDSP_vfix16(base, 1, int16Ptr, 1, vDSP_Length(sampleCount))
            }
        } else {
            if _micGainBuffer.count < sampleCount { _micGainBuffer = [Float](repeating: 0, count: sampleCount) }
            _micGainBuffer.withUnsafeMutableBufferPointer { floatSamplesPtr in
                guard let base = floatSamplesPtr.baseAddress else { return }
                vDSP_vflt16(int16Ptr, 1, base, 1, vDSP_Length(sampleCount))
                var g = gain
                vDSP_vsmul(base, 1, &g, base, 1, vDSP_Length(sampleCount))
                var minVal: Float = Float(Int16.min)
                var maxVal: Float = Float(Int16.max)
                vDSP_vclip(base, 1, &minVal, &maxVal, base, 1, vDSP_Length(sampleCount))
                vDSP_vfix16(base, 1, int16Ptr, 1, vDSP_Length(sampleCount))
            }
        }
        return sampleBuffer
    }

    private func applyGain(
        _ buffer: CMSampleBuffer,
        trackType: AudioTrackType
    ) -> CMSampleBuffer {

        let gain = (trackType == .app) ? self.appAddVolume : self.micAddVolume
        let safeGain = gain.isFinite ? gain : 1.0

        if safeGain > 1.0 {
            return amplifySIMD(buffer, gain: safeGain, trackType: trackType)
        }

        return buffer
    }


    // MARK: 音量統計
    private func processRMS(_ buffer: CMSampleBuffer, trackType: AudioTrackType, originalTime: CMSampleTimingInfo) {

        let now = CACurrentMediaTime()

        guard self.onAudioPage, now - self.lastRMSUpdateTime > self.rmsInterval else { return }
        self.lastRMSUpdateTime = now

        let retimed = retimeAudioBuffer(buffer, originalTime: originalTime)

        if let rms = rmsSIMD(from: retimed) {

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


    private var enqueueCount: Int = 0
    private var lastEnqueueLog: CFTimeInterval = 0
    private var _isEnqueuingApp = false
    private var _isEnqueuingMic = false
    private var _enqueueLock = os_unfair_lock()

    func enqueue(_ sampleBuffer: CMSampleBuffer, trackType: AudioTrackType, oringinaltime: CMSampleTimingInfo) {
        os_unfair_lock_lock(&_enqueueLock)
        switch trackType {
        case .app:
            guard !_isEnqueuingApp else { os_unfair_lock_unlock(&_enqueueLock); return }
            _isEnqueuingApp = true
        case .mic:
            guard !_isEnqueuingMic else { os_unfair_lock_unlock(&_enqueueLock); return }
            _isEnqueuingMic = true
        }
        os_unfair_lock_unlock(&_enqueueLock)

        enqueueCount += 1
        let pts = oringinaltime.presentationTimeStamp.seconds
        let now = CACurrentMediaTime()
        let enablePipeLog = RPConfig.shared.enablePipelineLog
        let shouldLog = enablePipeLog && (enqueueCount == 1 || enqueueCount % 3000 == 0 || (now - lastEnqueueLog) > 30.0)
        let localCount = enqueueCount

        Task.detached(priority: .high) { [weak self] in
            guard let self, self.isActive else {
                if let self { self.setEnqueuing(false, trackType: trackType) }
                return
            }
            defer {
                self.setEnqueuing(false, trackType: trackType)
            }

            guard await self.mediaMixer.isRunning else {
                if shouldLog { sendlog(message: "[AudioProcessor] ⚠️ #\(localCount) MediaMixer 未運行 PTS:\(String(format:"%.3f",pts))s") }
                return
            }


            if shouldLog {
                self.lastEnqueueLog = now
                sendlog(message: "[AudioProcessor] #\(localCount) 進入 track:\(trackType) PTS:\(String(format:"%.3f",pts))s mode:\(self.UseOringin ? "原始" : "專用")")
            }

            if self.UseOringin {

                let RSample = self.applyGain(sampleBuffer, trackType: trackType)
                self.processRMS(RSample, trackType: trackType, originalTime: oringinaltime)

                await self.mediaMixer.append(RSample, track: trackType.rawValue)

            } else {

                if let audioEngine = self.audioEngine, self.isActive {
                    audioEngine.process(sampleBuffer, track: trackType)
                }

                self.processRMS(sampleBuffer, trackType: trackType, originalTime: oringinaltime)

                if shouldLog { sendlog(message: "[AudioProcessor] #\(localCount) 送出MediaMixer track:\(trackType.rawValue)") }
                await self.mediaMixer.append(sampleBuffer, track: trackType.rawValue)
            }
        }
    }

    private func setEnqueuing(_ value: Bool, trackType: AudioTrackType) {
        os_unfair_lock_lock(&_enqueueLock)
        switch trackType {
        case .app: _isEnqueuingApp = value
        case .mic: _isEnqueuingMic = value
        }
        os_unfair_lock_unlock(&_enqueueLock)
    }




}
