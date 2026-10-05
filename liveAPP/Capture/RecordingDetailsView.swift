#if os(iOS)
import SwiftUI
import AVFoundation

private struct RecordingFileDetails {
    let duration: Double
    let bytes: Int64
    let encoded: CGSize
    let displayed: CGSize
    let fps: Float
    let videoRate: Float
    let videoCodec: String
    let audioCodecs: String

    static func codec(_ descriptions: [CMFormatDescription]) -> String {
        guard let format = descriptions.first else { return "—" }
        let code = CMFormatDescriptionGetMediaSubType(format)
        return String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 255) }, encoding: .ascii) ?? "—"
    }
    static func read(_ url: URL) async throws -> Self {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "RecordingDetails", code: 1, userInfo: [NSLocalizedDescriptionKey: AppLanguage.localized("recording.noVideo")])
        }
        let size = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        let fps = try await video.load(.nominalFrameRate)
        let rate = try await video.load(.estimatedDataRate)
        let videoCodec = codec(try await video.load(.formatDescriptions))
        var audioCodecs: [String] = []
        for audio in try await asset.loadTracks(withMediaType: .audio) {
            audioCodecs.append(codec(try await audio.load(.formatDescriptions)))
        }
        let bytes = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        return Self(duration: duration, bytes: bytes, encoded: size, displayed: bounds.size,
                    fps: fps, videoRate: rate, videoCodec: videoCodec,
                    audioCodecs: audioCodecs.isEmpty ? "—" : audioCodecs.joined(separator: ", "))
    }
}

@MainActor private final class RecordingDetailsCache {
    static let shared = RecordingDetailsCache()
    private var values: [URL: (String, RecordingFileDetails)] = [:]
    func read(_ url: URL) async throws -> RecordingFileDetails {
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let signature = "\(info.fileSize ?? 0):\(info.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let (stored, details) = values[url], stored == signature { return details }
        let details = try await RecordingFileDetails.read(url)
        try Task.checkCancellation()
        if values.count >= 32 { values.removeAll() }
        values[url] = (signature, details)
        return details
    }
}

@MainActor struct RecordingDetailsView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var details: RecordingFileDetails?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                if let d = details {
                    value("recording.duration", d.duration.isFinite ? String(format: "%.2f s", d.duration) : "—")
                    value("recording.size", ByteCountFormatter.string(fromByteCount: d.bytes, countStyle: .file))
                    value("recording.encodedSize", dimensions(d.encoded))
                    value("recording.displaySize", dimensions(d.displayed))
                    value("recording.fps", d.fps.isFinite && d.fps > 0 ? String(format: "%.3f fps", d.fps) : "—")
                    value("recording.videoRate", d.videoRate.isFinite && d.videoRate > 0 ? String(format: "%.0f kbps", d.videoRate / 1000) : "—")
                    value("recording.fileRate", d.duration.isFinite && d.duration > 0 ? String(format: "%.0f kbps", Double(d.bytes) * 8 / d.duration / 1000) : "—")
                    value("recording.videoCodec", d.videoCodec)
                    value("recording.audioCodec", d.audioCodecs)
                    Text(AppLanguage.localized("recording.infoHelp")).font(.caption).foregroundStyle(.secondary)
                    NavigationLink(AppLanguage.localized("recording.analyze")) { VideoBitrateView(initialURL: url) }
                } else if let error { Text(error).foregroundStyle(.red) }
                else { ProgressView() }
            }
            .navigationTitle(AppLanguage.localized("recording.details"))
            .toolbar { Button(AppLanguage.localized("logs.close")) { dismiss() } }
            .task {
                do { details = try await RecordingDetailsCache.shared.read(url) }
                catch is CancellationError { }
                catch { self.error = error.localizedDescription }
            }
        }
    }
    private func dimensions(_ size: CGSize) -> String {
        guard size.width.isFinite, size.height.isFinite else { return "—" }
        return String(format: "%.0f × %.0f", abs(size.width), abs(size.height))
    }
    private func value(_ key: String, _ text: String) -> some View {
        LabeledContent(AppLanguage.localized(key)) { Text(text).textSelection(.enabled) }
    }
}
#endif
