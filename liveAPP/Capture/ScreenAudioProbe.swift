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
    private let session: String
    init(session: String) { self.session = session }

    /// 記錄 SCStream 真正交付的 ASBD、批次長度與 PTS；不假定 ReplayKit 的 1024 samples。
    func observe(_ sample: CMSampleBuffer, track: UInt8) {
        guard let description = sample.formatDescription,
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return }
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
    }
    /// 此計數確認 Mixer 已將 buffer 交付輸出端，比 mixerOutputFrames 更接近 RTMP 輸入。
    func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        return "delivered=\(mixedBuffers) format=\(mixedFormat)"
    }
}
#endif
