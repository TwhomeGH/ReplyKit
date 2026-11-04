import AVFoundation
import Foundation
import Testing
@testable import liveAPP

/// 用固定合成影片驗證另存契約；真正的壓縮仍需 Apple SDK 與可用編碼器。
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

    /// iOS 不可使用 macOS 專屬 Writer 矩陣，也不可將 240M 偷換成 BT.601／709。
    @Test(arguments: ["YCbCrMatrix#7", "SMPTE_240M_1995"])
    func unsupportedIOSMatrixIsRejected(value: String) {
        #expect(throws: (any Error).self) {
            _ = try RecordingTranscoder.normalizedColorMatrix(value)
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

    /// 不完整來源可用自動，但不可在嚴格或轉色模式中猜測缺少資訊。
    @Test func colorPolicyExplainsIncompleteSource() {
        let info = CompressionColorInfo(extensions: [
            kCMFormatDescriptionExtension_YCbCrMatrix as String: "YCbCrMatrix#5"
        ])
        #expect(info.matrixLabel == "BT.601")
        #expect(info.restriction(for: .automatic) == nil)
        #expect(info.restriction(for: .preserve) != nil)
        #expect(info.restriction(for: .bt709) != nil)
        #expect(info.preview(for: .automatic).contains("待確認"))
        #expect(info.summary.contains("範圍：未提供"))
    }

    /// 範圍缺失不能當作有限範圍；手動保留與轉色都需要明確來源範圍。
    @Test func strictColorRequiresKnownRange() {
        var values: [String: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries as String: AVVideoColorPrimaries_ITU_R_709_2,
            kCMFormatDescriptionExtension_TransferFunction as String: AVVideoTransferFunction_ITU_R_709_2,
            kCMFormatDescriptionExtension_YCbCrMatrix as String: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
        let unknown = CompressionColorInfo(extensions: values)
        #expect(unknown.restriction(for: .preserve) != nil)
        #expect(unknown.restriction(for: .bt709) != nil)
        values[kCMFormatDescriptionExtension_FullRangeVideo as String] = true
        let known = CompressionColorInfo(extensions: values)
        #expect(known.restriction(for: .preserve) == nil)
        #expect(known.summary.contains("全範圍"))
    }

    /// 兩種壓縮路徑都必須保留原檔，並輸出具有效時長、可解碼的影片。
    @Test(.serialized, arguments: [false, true])
    func separateOutputKeepsSourceBytes(systemQuality: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("source.mp4")
        let destination = folder.appendingPathComponent("output.mp4")
        // 樣本隨測試 bundle 複製；不在準備階段額外啟動 Writer，避免將準備逾時誤認為壓縮失敗。
        let fixture = try #require(Bundle(for: CompressionFixtureBundle.self)
            .url(forResource: "compression-source", withExtension: "mp4"),
            "測試 bundle 缺少 compression-source.mp4；請檢查 Resources membership")
        try FileManager.default.copyItem(at: fixture, to: source)

        let original = try Data(contentsOf: source)
        _ = try await RecordingTranscoder.compress(url: source, asset: AVURLAsset(url: source),
            settings: .init(enabled: true, hevc: false, megabits: 1, longestEdge: 0, fpsLimit: 0, systemQuality: systemQuality),
            destination: destination, audioMode: .remove,
            qualityPreset: systemQuality ? .highest : nil)
        #expect(try Data(contentsOf: source) == original)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let output = AVURLAsset(url: destination)
        let tracks = try await output.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        #expect(tracks.count == 1)
        let duration = try await output.load(.duration).seconds
        #expect(abs(duration - 1) < 0.1)

        // 讀取解碼後影格，避免只有容器／軌道存在、實際沒有可播放內容也通過。
        let reader = try AVAssetReader(asset: output)
        let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        try #require(reader.canAdd(decoded))
        reader.add(decoded)
        try #require(reader.startReading(), "輸出解碼無法開始：\(String(describing: reader.error))")
        defer { reader.cancelReading() }
        let first = try #require(decoded.copyNextSampleBuffer(),
            "輸出沒有可解碼影格：\(String(describing: reader.error))")
        #expect(CMSampleBufferGetImageBuffer(first) != nil)
    }
}

/// 以測試 target 內的類別定位 bundle，避免誤從主 App 尋找測試資源。
private final class CompressionFixtureBundle: NSObject {}
