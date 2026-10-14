#if os(iOS)
import Foundation
import AVFoundation
import HaishinKit
import Testing
@testable import liveAPP

/// 切片錄製 單元測試
@MainActor struct SegmentedRecordingTests {

    /// 以稀疏合成影格跨過切段邊界，驗證檔案完成與 manifest 對應。
    @Test func completedSegmentsRemainIndependent() async throws {
        let name = "SegmentedRecordingTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("h264", forKey: "directRecordingCodec")
        defaults.set("native", forKey: "recordingCanvasMode")
        defaults.set(60, forKey: "recordingSegmentSeconds")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = RecordingLibrary(directory: directory)
        let sink = SegmentedRecordingSink(settings: DirectRecordingSettings(defaults: defaults), library: library) { message in
            Issue.record(Comment(rawValue: message))
        }
        let mixer = MediaMixer(captureSessionMode: .manual, multiTrackAudioMixingEnabled: true)
        for seconds in [0.0, 1.0, 61.0, 62.0] {
            var pixel: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel)
            #expect(status == kCVReturnSuccess)
            let image = try #require(pixel)
            CVPixelBufferLockBaseAddress(image, [])
            if let base = CVPixelBufferGetBaseAddress(image) { memset(base, 0, CVPixelBufferGetDataSize(image)) }
            CVPixelBufferUnlockBaseAddress(image, [])
            var format: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample)
            sink.mixer(mixer, didOutput: try #require(sample))
        }
        await sink.finish()
        #expect(library.recordings.count == 2)
        // 分別驗證完成狀態與實際大小，讓 CI 能指出是哪個契約失敗。
        for item in library.recordings {
            let context = "segment=\(String(describing: item.segmentNumber)) phase=\(item.phase) bytes=\(item.bytes) message=\(item.message ?? "") mailbox=\(sink.summary)"
            #expect(item.phase == .ready, Comment(rawValue: context))
            let attributes = try FileManager.default.attributesOfItem(atPath: library.fileURL(for: item.id).path)
            let actualBytes = try #require((attributes[.size] as? NSNumber)?.int64Value)
            #expect(actualBytes > 0, Comment(rawValue: context))
            #expect(item.bytes == actualBytes, Comment(rawValue: context))
        }
        #expect(Set(library.recordings.compactMap(\.segmentGroup)).count == 1)
        #expect(Set(library.recordings.compactMap(\.segmentNumber)) == [1, 2])
        let mergedID = try await library.merge(group: try #require(library.recordings.first?.segmentGroup))
        #expect(library.recordings.count == 3)
        #expect(library.recordings.first(where: { $0.id == mergedID })?.phase == .ready)
        #expect(library.recordings.filter { $0.segmentGroup != nil }.count == 2)
        let reopened = RecordingLibrary(directory: directory)
        #expect(reopened.recordings.allSatisfy { $0.phase == .ready })
    }
    /// 新段畫面先到，舊段音訊後到時，應仍寫入舊段而非被 beforeStart 丟棄。
    @Test(arguments: [false, true]) func lateAudioReturnsToPreviousSegment(crossesBoundary: Bool) async throws {
        let name = "LateAudio." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("h264", forKey: "directRecordingCodec")
        defaults.set("native", forKey: "recordingCanvasMode")
        defaults.set(60, forKey: "recordingSegmentSeconds")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let library = RecordingLibrary(directory: directory)
        let router = SegmentedRecordingWriter(settings: DirectRecordingSettings(defaults: defaults), library: library)
        try await router.append(videoSample(seconds: 100))
        try await router.append(videoSample(seconds: 159))
        try await router.append(videoSample(seconds: 160))
        // 主動模擬跨軌道交付順序，無須等待真實 60 秒。
        try await router.append(audioSample(seconds: crossesBoundary ? 159.99 : 159.5))
        try await router.append(audioSample(seconds: 160.5))
        try await router.append(videoSample(seconds: 161))
        try await router.finishSegment()
        #expect(library.recordings.count == 2)
        for item in library.recordings {
            #expect(item.phase == .ready)
            let asset = AVURLAsset(url: library.fileURL(for: item.id))
            let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
            let decoded = try audibleStart(asset: asset, track: track)
            let expected = item.segmentNumber == 1 ? (crossesBoundary ? 59.99 : 59.5) : (crossesBoundary ? 0.0 : 0.5)
            // 驗證解碼後訊號的實際位置；第一個封包可能是填補或前置資料，不能代表聲音起點。
            let actual = try #require(decoded.audiblePTS, "片段沒有解碼出有效音訊")
            let delta = actual - expected
            let audioRange = try await track.load(.timeRange)
            let assetDuration = try await asset.load(.duration)
            let videoTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let videoRange = try await videoTrack.load(.timeRange)
            let context = """
                crossesBoundary=\(crossesBoundary) segment=\(item.segmentNumber ?? -1)
                expectedSignalPTS=\(expected) actualSignalPTS=\(actual) deltaSeconds=\(delta)
                firstDecodedPTS=\(String(describing: decoded.firstPTS)) detectionThreshold=0.01
                audioRangeStart=\(audioRange.start.seconds) audioRangeDuration=\(audioRange.duration.seconds)
                videoRangeStart=\(videoRange.start.seconds) videoRangeDuration=\(videoRange.duration.seconds)
                assetDuration=\(assetDuration.seconds) phase=\(item.phase) message=\(item.message ?? "none")
                """
            #expect(abs(delta) < 0.1, Comment(rawValue: context))
        }
    }

    /// 解碼整條音軌尋找測試訊號；零值前置資料不算聲音，真實提前仍會使原時間斷言失敗。
    /// - Returns: 第一批解碼 PTS，以及首個任一聲道絕對振幅超過 0.01 的時間；沒有訊號時為 nil。
    private func audibleStart(asset: AVAsset, track: AVAssetTrack) throws -> (firstPTS: Double?, audiblePTS: Double?) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "RecordingTest", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "無法開始解碼音訊"])
        }
        defer { reader.cancelReading() }
        var firstPTS: Double?
        while let sample = output.copyNextSampleBuffer() {
            if firstPTS == nil { firstPTS = sample.presentationTimeStamp.seconds }
            let count = sample.numSamples
            if count == 0 { continue }
            let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: 48000, channels: 2, interleaved: true))
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            pcm.frameLength = AVAudioFrameCount(count)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
                frameCount: Int32(count), into: pcm.mutableAudioBufferList)
            try #require(status == noErr)
            let data = try #require(pcm.floatChannelData)[0]
            for frame in 0..<count {
                if abs(data[frame * 2]) > 0.01 || abs(data[frame * 2 + 1]) > 0.01 {
                    return (firstPTS, sample.presentationTimeStamp.seconds + Double(frame) / 48000)
                }
            }
        }
        if let error = reader.error { throw error }
        return (firstPTS, nil)
    }

    /// 建立固定尺寸、指定時間戳的測試畫面。
    private func videoSample(seconds: Double) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel)
        #expect(status == kCVReturnSuccess)
        let image = try #require(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        if let base = CVPixelBufferGetBaseAddress(image) { memset(base, 0, CVPixelBufferGetDataSize(image)) }
        CVPixelBufferUnlockBaseAddress(image, [])
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format)
        #expect(formatStatus == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample)
        #expect(sampleStatus == noErr)
        return try #require(sample)
    }

    /// 左右片段拼回原資料，幀數、聲道內容及時間戳都不得丟失或錯位。
    @Test(arguments: [false, true])
    func pcmSlicesPreserveChannelsAndTiming(interleaved: Bool) throws {
        let source = try audioSample(seconds: 100, interleaved: interleaved)
        let left = try RecordingPCMSlicer.copy(source, start: 0, count: 480)
        let right = try RecordingPCMSlicer.copy(source, start: 480, count: 1568)
        #expect(left.numSamples + right.numSamples == source.numSamples)
        #expect(abs((left.presentationTimeStamp + left.duration - right.presentationTimeStamp).seconds) < 0.000001)
        #expect(abs((right.presentationTimeStamp + right.duration - source.presentationTimeStamp - source.duration).seconds) < 0.000001)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48000, channels: 2, interleaved: interleaved))
        for (part, offset) in [(left, 0), (right, 480)] {
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(part.numSamples)))
            pcm.frameLength = AVAudioFrameCount(part.numSamples)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(part, at: 0,
                frameCount: Int32(part.numSamples), into: pcm.mutableAudioBufferList)
            #expect(status == noErr)
            let channels = try #require(pcm.floatChannelData)
            for channel in 0..<2 {
                for frame in 0..<part.numSamples {
                    let expected = Float(channel * 2048 + offset + frame) / 8192
                    let actual = interleaved ? channels[0][frame * 2 + channel] : channels[channel][frame]
                    #expect(actual == expected)
                }
            }
        }
    }

    /// 建立 2048 幀 PCM，時間戳與視訊共用同一時間軸。
    private func audioSample(seconds: Double, interleaved: Bool = false) throws -> CMSampleBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048))
        buffer.frameLength = 2048
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<2048 {
                let value = Float(channel * 2048 + frame) / 8192
                if interleaved { channels[0][frame * 2 + channel] = value }
                else { channels[channel][frame] = value }
            }
        }
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format.formatDescription, sampleCount: 2048,
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48000),
            packetDescriptions: nil, sampleBufferOut: &sample)
        #expect(status == noErr)
        let result = try #require(sample)
        let copyStatus = CMSampleBufferSetDataBufferFromAudioBufferList(result,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffer.audioBufferList)
        #expect(copyStatus == noErr)
        return result
    }

}
#endif
