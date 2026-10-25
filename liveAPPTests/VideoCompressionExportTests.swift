import AVFoundation
import Foundation
import Testing
@testable import liveAPP

/// 用小型合成影片驗證另存契約；需 Apple SDK 與可用 H.264 編碼器。
struct VideoCompressionExportTests {
    @Test func separateOutputKeepsSourceBytes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let width = 320, height = 240
        let source = folder.appendingPathComponent("source.mp4")
        let destination = folder.appendingPathComponent("output.mp4")
        let writer = try AVAssetWriter(outputURL: source, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 200_000,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoMaxKeyFrameIntervalDurationKey: 1
            ] as [String: Any]
        ])
        input.expectsMediaDataInRealTime = false
        // 交由 adaptor 建立像素緩衝池，取得編碼器需要的 IOSurface-backed 緩衝。
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ])
        guard writer.canAdd(input) else { throw failure("無法加入測試影格輸入") }
        writer.add(input)
        guard writer.startWriting() else { throw failure("無法開始寫入測試影片", writer.error) }
        writer.startSession(atSourceTime: .zero)
        let pool = try #require(adaptor.pixelBufferPool, "像素緩衝池未建立")

        // 十格足以驗證時長與軌道契約，也縮短模擬器的軟體編碼時間。
        for frame in 0..<10 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else {
                    throw failure("等待測試影格輸入逾時", writer.error)
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess else {
                throw failure("無法取得測試影格緩衝")
            }
            let pixel = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            if let base = CVPixelBufferGetBaseAddress(pixel) {
                memset(base, 128, CVPixelBufferGetBytesPerRow(pixel) * height)
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw failure("無法附加測試影格", writer.error)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw failure("測試影片未完成", writer.error) }

        let original = try Data(contentsOf: source)
        _ = try await RecordingTranscoder.compress(url: source, asset: AVURLAsset(url: source),
            settings: .init(enabled: true, hevc: false, megabits: 1, longestEdge: 0, fpsLimit: 0),
            destination: destination, audioMode: .remove)
        #expect(try Data(contentsOf: source) == original)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let tracks = try await AVURLAsset(url: destination).loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
    }

    /// 保留底層錯誤以指出失敗階段，避免只看到籠統的檔案錯誤。
    private func failure(_ stage: String, _ error: Error? = nil) -> NSError {
        guard let error else {
            return NSError(domain: "VideoCompressionExportTests", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: stage])
        }
        return NSError(domain: "VideoCompressionExportTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "\(stage)：\(error.localizedDescription)",
            NSUnderlyingErrorKey: error
        ])
    }
}
