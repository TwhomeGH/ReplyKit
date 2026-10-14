#if os(iOS)
import Foundation
@preconcurrency import AVFoundation

/// 依 PCM 幀範圍複製音訊，支援交錯與非交錯聲道；不使用不支援平面音訊的通用子樣本 API。
enum RecordingPCMSlicer {
    /// 建立獨立的 PCM 子樣本，保留格式並依來源取樣率平移時間戳。
    /// - Parameters:
    ///   - sample: 已就緒的線性 PCM 音訊。
    ///   - start: 從零開始的音訊幀索引。
    ///   - count: 要複製的音訊幀數，必須大於零。
    /// - Returns: 包含指定幀範圍與原聲道排列的新樣本。
    /// - Throws: 範圍／格式無效、緩衝配置或 CoreMedia 複製失敗；錯誤含失敗階段。
    static func copy(_ sample: CMSampleBuffer, start: Int, count: Int) throws -> CMSampleBuffer {
        func failure(_ stage: String, code: OSStatus = -1) -> NSError {
            NSError(domain: "RecordingBoundary", code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: "PCM 切分失敗：\(stage)，start=\(start)，count=\(count)。"
            ])
        }
        let total = CMSampleBufferGetNumSamples(sample)
        guard start >= 0, count > 0, start <= total, count <= total - start,
              start <= Int(Int32.max), count <= Int(Int32.max) else {
            throw failure("invalidRange")
        }
        guard CMSampleBufferDataIsReady(sample),
              let formatDescription = sample.formatDescription,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              description.pointee.mFormatID == kAudioFormatLinearPCM,
              description.pointee.mSampleRate.isFinite, description.pointee.mSampleRate > 0,
              sample.presentationTimeStamp.seconds.isFinite else {
            throw failure("invalidPCMFormatOrTiming")
        }
        var asbd = description.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw failure("allocatePCM")
        }
        pcm.frameLength = AVAudioFrameCount(count)
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: Int32(start),
            frameCount: Int32(count), into: pcm.mutableAudioBufferList)
        guard copyStatus == noErr else { throw failure("copyPCM", code: copyStatus) }

        // start 是音訊幀數，不是位元組或聲道樣本總數。
        let offset = CMTime(seconds: Double(start) / asbd.mSampleRate, preferredTimescale: 1_000_000_000)
        var result: CMSampleBuffer?
        let createStatus = CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: formatDescription, sampleCount: count,
            presentationTimeStamp: sample.presentationTimeStamp + offset,
            packetDescriptions: nil, sampleBufferOut: &result)
        guard createStatus == noErr, let result else { throw failure("createSample", code: createStatus) }
        // 複製資料到新樣本，使其生命週期不依賴此區域 PCM 緩衝。
        let attachStatus = CMSampleBufferSetDataBufferFromAudioBufferList(result,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.audioBufferList)
        guard attachStatus == noErr else { throw failure("attachPCM", code: attachStatus) }
        return result
    }
}
#endif
