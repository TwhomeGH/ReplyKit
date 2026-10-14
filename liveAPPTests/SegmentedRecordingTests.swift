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
        let reopened = RecordingLibrary(directory: directory)
        #expect(reopened.recordings.allSatisfy { $0.phase == .ready })
    }
}
#endif
