#if os(iOS) && SCREEN_CAPTURE_KIT_IOS27 && canImport(ScreenCaptureKit) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
import AVFoundation
import HaishinKit

/// 只保留格式與計數，不保留音訊 buffer。回呼與診斷取樣之間由鎖保護。
final class ScreenAudioProbe: MediaMixerOutput, @unchecked Sendable {
    let videoTrackId: UInt8? = nil
    let audioTrackId: UInt8? = UInt8.max
    private let lock = NSLock()
    private var formats: [UInt8: String] = [:]
    private var mixedBuffers = 0
    private var mixedFormat = "unknown"
    private var lastMeterTime: [String: TimeInterval] = [:]
    private var meterInterval: TimeInterval = 1
    private let session: String

    /// 限頻狀態與格式快照共用鎖；不在鎖內複製或遍歷 PCM。
    private func shouldMeasure(_ channel: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (lastMeterTime[channel] ?? -.infinity) >= meterInterval else { return false }
        lastMeterTime[channel] = now
        return true
    }

    private func setMeterVisible(_ visible: Bool) {
        lock.lock()
        meterInterval = visible ? 0.2 : 1
        lock.unlock()
    }

    /// 僅跨 actor 傳送純量與取樣時間，不持有音訊 buffer。
    private func report(_ rms: Float?, channel: String) {
        let at = Date()
        Task { @MainActor [weak self, session] in
            LiveVolumeModel.shared.reportCapture(session, channel: channel, rms: rms, at: at)
            self?.setMeterVisible(LiveVolumeModel.shared.monitoringVisible)
        }
    }

    init(session: String) { self.session = session }

    /// 記錄 SCStream 真正交付的 ASBD、批次長度與 PTS；不假定 ReplayKit 的 1024 samples。
    func observe(_ sample: CMSampleBuffer, track: UInt8) {
        guard let description = sample.formatDescription,
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return }
        let channel = track == 0 ? "app" : "mic"
        if shouldMeasure(channel) { report(AudioMeterPCM.rms(sample), channel: channel) }
        let a = pointer.pointee
        let signature = "formatID=\(a.mFormatID) sampleRate=\(a.mSampleRate) channels=\(a.mChannelsPerFrame) bits=\(a.mBitsPerChannel) flags=\(a.mFormatFlags) bytesPerFrame=\(a.mBytesPerFrame) framesPerPacket=\(a.mFramesPerPacket) float=\((a.mFormatFlags & kAudioFormatFlagIsFloat) != 0) nonInterleaved=\((a.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0)"
        lock.lock()
        let changed = formats[track] != signature
        formats[track] = signature
        lock.unlock()
        if changed {
            let check = inspectPCM(sample, asbd: a)
            sendlog(message: "[CaptureAudioRead] session=\(session) track=\(track) \(check)")
            sendlog(message: "[CaptureAudioFormat] session=\(session) track=\(track) \(signature) samples=\(sample.numSamples) pts=\(sample.presentationTimeStamp.seconds) duration=\(sample.duration.seconds)")
        }
    }

    /// 首次或格式變更才複製一批 PCM 做可讀性檢查，不修改送給 Mixer 的來源。
    private func inspectPCM(_ sample: CMSampleBuffer, asbd: AudioStreamBasicDescription) -> String {
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return "pcm=false read=notAttempted" }
        guard sample.numSamples > 0, sample.numSamples <= 65536 else { return "read=invalidSampleCount" }
        var description = asbd
        guard let format = AVAudioFormat(streamDescription: &description),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)) else {
            return "read=formatOrAllocationFailed"
        }
        buffer.frameLength = AVAudioFrameCount(sample.numSamples)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
            frameCount: Int32(sample.numSamples), into: buffer.mutableAudioBufferList)
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
            sampleRate: min(48000, format.sampleRate), channels: min(2, format.channelCount),
            interleaved: format.isInterleaved)
        let converter = target.flatMap { AVAudioConverter(from: format, to: $0) }
        return "pcm=true copyStatus=\(status) converterCreated=\(converter != nil)"
    }

    func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {}
    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async {}
    func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        lock.lock()
        mixedBuffers += 1
        mixedFormat = "\(buffer.format.sampleRate)Hz \(buffer.format.channelCount)ch"
        lock.unlock()
        if shouldMeasure("mixed") { report(AudioMeterPCM.rms(buffer), channel: "mixed") }
    }
    /// 此計數確認 Mixer 已將 buffer 交付輸出端，比 mixerOutputFrames 更接近 RTMP 輸入。
    func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        return "delivered=\(mixedBuffers) format=\(mixedFormat)"
    }
}
#endif
