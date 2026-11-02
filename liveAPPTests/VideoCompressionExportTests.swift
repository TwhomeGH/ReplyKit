import AVFoundation
import Foundation
import Testing
@testable import liveAPP

/// 用小型合成影片驗證另存契約；需 Apple SDK 與可用 H.264 編碼器。
struct VideoCompressionExportTests {
    /// 真實失敗來源只有 matrix #5；不可捏造 primaries／transfer 或誤標 BT.709。
    @Test func partialBT601MetadataRemainsPartial() throws {
        let colors = try RecordingTranscoder.mappedColorProperties([
            kCMFormatDescriptionExtension_YCbCrMatrix as String: "YCbCrMatrix#5"
        ])
        #expect(colors.count == 1)
        #expect(colors[AVVideoYCbCrMatrixKey] == AVVideoYCbCrMatrix_ITU_R_601_4)
        #expect(colors[AVVideoColorPrimariesKey] == nil)
        #expect(colors[AVVideoTransferFunctionKey] == nil)
    }

    /// 完整合法設定必須保持原意，未知矩陣不得默默降級。
    @Test func completeColorsAndUnknownMatrix() throws {
        let colors = try RecordingTranscoder.mappedColorProperties([
            kCMFormatDescriptionExtension_ColorPrimaries as String: AVVideoColorPrimaries_ITU_R_709_2,
            kCMFormatDescriptionExtension_TransferFunction as String: AVVideoTransferFunction_ITU_R_709_2,
            kCMFormatDescriptionExtension_YCbCrMatrix as String: AVVideoYCbCrMatrix_ITU_R_709_2
        ])
        #expect(colors.count == 3)
        #expect(colors[AVVideoYCbCrMatrixKey] == AVVideoYCbCrMatrix_ITU_R_709_2)
        #expect(throws: (any Error).self) {
            _ = try RecordingTranscoder.normalizedColorMatrix("YCbCrMatrix#999")
        }
    }

    /// 附件映射不改像素格式；解碼器已指定的矩陣優先於來源回補。
    @Test func decodedMatrixPreservesRangeAndDecoderChoice() throws {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        #expect(status == kCVReturnSuccess)
        let image = try #require(buffer)
        CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey,
            "YCbCrMatrix#5" as CFString, .shouldPropagate)
        var description: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescriptionOut: &description) == noErr)
        let format = try #require(description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var bufferSample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescription: format, sampleTiming: &timing,
            sampleBufferOut: &bufferSample) == noErr)
        let sample = try #require(bufferSample)
        try RecordingTranscoder.normalizeDecodedColor(sample, sourceMatrix: nil)
        let mapped = CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, nil) as? String
        #expect(mapped == AVVideoYCbCrMatrix_ITU_R_601_4)
        #expect(CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        try RecordingTranscoder.normalizeDecodedColor(sample, sourceMatrix: AVVideoYCbCrMatrix_ITU_R_601_4)
        let retained = CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, nil) as? String
        #expect(retained == AVVideoYCbCrMatrix_ITU_R_709_2)
    }

    @Test(arguments: [false, true])
    func separateOutputKeepsSourceBytes(systemQuality: Bool) async throws {
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
            settings: .init(enabled: true, hevc: false, megabits: 1, longestEdge: 0, fpsLimit: 0, systemQuality: systemQuality),
            destination: destination, audioMode: .remove,
            qualityPreset: systemQuality ? .highest : nil)
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
