import AVFoundation
import Foundation
import Testing
@testable import liveAPP

/// 用小型合成影片驗證另存契約；需 Apple SDK 與可用 H.264 編碼器。
struct VideoCompressionExportTests {
    @Test func separateOutputKeepsSourceBytes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("source.mp4")
        let destination = folder.appendingPathComponent("output.mp4")
        let writer = try AVAssetWriter(outputURL: source, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else { throw CocoaError(.fileWriteUnknown) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            #expect(status == kCVReturnSuccess)
            let pixel = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            if let base = CVPixelBufferGetBaseAddress(pixel) {
                memset(base, 128, CVPixelBufferGetBytesPerRow(pixel) * 64)
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            let appended = adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30))
            #expect(appended)
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        let original = try Data(contentsOf: source)
        _ = try await RecordingTranscoder.compress(url: source, asset: AVURLAsset(url: source),
            settings: .init(enabled: true, hevc: false, megabits: 1, longestEdge: 0, fpsLimit: 0),
            destination: destination, audioMode: .remove)
        #expect(try Data(contentsOf: source) == original)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let tracks = try await AVURLAsset(url: destination).loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
    }
}
