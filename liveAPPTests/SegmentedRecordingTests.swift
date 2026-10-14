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
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            #expect(reader.startReading())
            let first = try #require(output.copyNextSampleBuffer())
            let expected = item.segmentNumber == 1 ? (crossesBoundary ? 59.99 : 59.5) : (crossesBoundary ? 0.0 : 0.5)
            #expect(abs(first.presentationTimeStamp.seconds - expected) < 0.1)
            reader.cancelReading()
        }
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

    /// 建立 2048 幀 PCM，時間戳與視訊共用同一時間軸。
    private func audioSample(seconds: Double) throws -> CMSampleBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048))
        buffer.frameLength = 2048
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<2048 { channels[channel][frame] = 0.1 }
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
