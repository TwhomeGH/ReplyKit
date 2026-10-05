#if os(iOS)
import SwiftUI
import AVFoundation

// MARK: - 完成錄影的檔案資訊

/// 從實際檔案讀取的資訊快照，不使用開播設定推算，也不逐幀解碼。
/// 影像欄位取第一條 video track；音訊編碼則列出所有 audio tracks。
private struct RecordingFileDetails {
    /// 容器時長，單位為秒；無效數值由顯示層轉成「—」。
    let duration: Double
    /// 完整檔案位元組數，包含影像、音訊及容器封裝。
    let bytes: Int64
    /// video track 的 naturalSize，尚未套用方向矩陣。
    let encoded: CGSize
    /// 將 preferredTransform 套到 naturalSize 後的外接矩形尺寸。
    let displayed: CGSize
    /// nominalFrameRate：軌道標稱 FPS，不代表可變幀率影片的逐幀實測平均。
    let fps: Float
    /// estimatedDataRate：影像軌估計碼率，單位 bit/s，不含其他軌與封裝。
    let videoRate: Float
    /// 第一條影像軌的媒體子類型 FourCC。
    let videoCodec: String
    /// 各音訊軌的 FourCC，以逗號分隔；沒有音訊時顯示「—」。
    let audioCodecs: String

    /// 取第一份格式描述的媒體子類型，依高位元組到低位元組轉成 FourCC。
    /// 保留原始代碼供排錯；格式缺失或無法解碼為 ASCII 時回傳「—」。
    static func codec(_ descriptions: [CMFormatDescription]) -> String {
        guard let format = descriptions.first else { return "—" }
        let code = CMFormatDescriptionGetMediaSubType(format)
        return String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 255) }, encoding: .ascii) ?? "—"
    }
    /// 非同步載入已完成影片的軌道中繼資料，不修改或複製原片。
    /// - Parameter url: 可讀取的本地影片 URL；由呼叫端確保錄製與方向收尾已完成。
    /// - Returns: 容器大小、時長與軌道資訊快照。
    /// - Throws: 檔案／AVAsset 讀取錯誤，或找不到影像軌時的 RecordingDetails 錯誤。
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

// MARK: - 有界資訊快取

/// 共用主執行緒快取，避免重開詳細頁時重複讀取未變更的檔案。
/// 僅保存資訊快照，不持有 AVAsset、影格或影片資料。
@MainActor private final class RecordingDetailsCache {
    static let shared = RecordingDetailsCache()
    private var values: [URL: (String, RecordingFileDetails)] = [:]
    /// 以 URL、大小與修改時間判斷命中；檔案變更時重新載入。
    /// 這是輕量失效判斷，不做內容雜湊，也不合併同時進行的重複讀取。
    func read(_ url: URL) async throws -> RecordingFileDetails {
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let signature = "\(info.fileSize ?? 0):\(info.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let (stored, details) = values[url], stored == signature { return details }
        let details = try await RecordingFileDetails.read(url)
        // 離開畫面而取消的讀取不寫入快取；AVAsset 載入結束後在此確認取消。
        try Task.checkCancellation()
        // 到達容量時整批清空，並非 LRU；將資訊記憶體限制在最多 32 份。
        if values.count >= 32 { values.removeAll() }
        values[url] = (signature, details)
        return details
    }
}

// MARK: - 詳細資訊畫面

/// 按需顯示檔案資訊，完整碼率分析另由使用者點擊觸發。
/// 錄影列表僅對 ready 狀態開放此頁；此頁本身不變更錄影生命週期。
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
                    // 整檔平均 = bytes × 8 ÷ 秒數，再換算 kbps；不能當成純影像碼率。
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
    /// 防止非有限尺寸進入格式化，旋轉／鏡射後以正值像素尺寸顯示。
    private func dimensions(_ size: CGSize) -> String {
        guard size.width.isFinite, size.height.isFinite else { return "—" }
        return String(format: "%.0f × %.0f", abs(size.width), abs(size.height))
    }
    /// 統一使用 App 語言設定解析標籤，數值保留文字選取功能。
    private func value(_ key: String, _ text: String) -> some View {
        LabeledContent(AppLanguage.localized(key)) { Text(text).textSelection(.enabled) }
    }
}
#endif
