import Foundation
import AVFoundation
import Combine
import UIKit

/// 全 App 單一手動壓縮任務。來源僅讀取；新產物放在 App 文件共享目錄。
@MainActor final class VideoCompressionModel: ObservableObject {
    static let shared = VideoCompressionModel()
    @Published private(set) var source: URL?
    @Published private(set) var details: RecordingFileDetails?
    @Published private(set) var output: URL?
    @Published private(set) var outputDetails: RecordingFileDetails?
    @Published private(set) var busy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var message = "選擇一個影片開始。"
    /// 來源可建立 MP4 匯出的系統預設；換片成功時一起更新。
    @Published private(set) var qualityPresets: [RecordingTranscoder.QualityPreset] = []
    @Published private(set) var systemExportRunning = false
    private var jobID = UUID()
    private var backgroundObserver: AnyCancellable?
    private var importedSource: URL?

    private init() {
        backgroundObserver = NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.cancel() } }
    }

    /// 檔案選取器錯誤同樣可見，避免選檔後沒有回應。
    func report(_ error: Error) { message = error.localizedDescription }

    /// 僅採近期已發布的擴展回報，避免舊狀態永久阻止手動壓縮。
    private var captureBusy: Bool {
        if CaptureCoordinator.shared.isBusy { return true }
        guard let value = StreamDiagnosticsModel.shared.snapshots["ReplayKit"],
              Date().timeIntervalSince(value.sampledAt) < 15 else { return false }
        return value.phase.lowercased().contains("publishing")
    }

    private var task: Task<Void, Never>?

    /// 在安全範圍授權有效期間讀取資訊；只保存 URL 與純量，不整片載入記憶體。
    func select(_ url: URL) {
        guard !busy else { return }
        // 相簿匯入的暫存副本只保留最近一份；載入新來源時刪除，避免大型影片累積。
        if importedSource != url, !discardImportedSource() { return }
        busy = true
        task = Task {
            defer { busy = false; task = nil }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let info = try await RecordingFileDetails.read(url)
                try Task.checkCancellation()
                guard info.duration.isFinite, info.duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
                let asset = AVURLAsset(url: url)
                let compatible = AVAssetExportSession.exportPresets(compatibleWith: asset)
                let presets = RecordingTranscoder.QualityPreset.allCases.filter {
                    compatible.contains($0.name) &&
                    AVAssetExportSession(asset: asset, presetName: $0.name)?.supportedFileTypes.contains(.mp4) == true
                }
                try Task.checkCancellation()
                qualityPresets = presets
                source = url; details = info; output = nil; outputDetails = nil
                progress = 0
                message = "已載入。原檔會保留。"
            } catch { message = Task.isCancelled ? "已取消。" : error.localizedDescription }
        }
    }

    /// 相簿影片由 App 複製到暫存目錄；下一支來源載入時清除，只保留最近一份。
    func selectImported(_ url: URL) {
        guard !busy else { VideoWorkFiles.discard(url); return }
        guard discardImportedSource() else { VideoWorkFiles.discard(url); return }
        select(url)
        importedSource = url
    }

    /// 刪除失敗保留持有路徑，讓下一次可重試並向畫面回報。
    private func discardImportedSource() -> Bool {
        guard let importedSource else { return true }
        guard VideoWorkFiles.discard(importedSource) else {
            message = "來源暫存清理失敗，請查看日誌並重試。"
            return false
        }
        self.importedSource = nil
        return true
    }

    /// 手動釋放來源副本；保留已完成成品，執行中不可清除。
    func clearSource() {
        guard !busy else { return }
        guard discardImportedSource() else { return }
        source = nil; details = nil; qualityPresets = []
        message = "已清除目前來源，成品保留。"
    }

    /// 固定本次設定，等待本機擷取結束後轉碼；新檔驗證成功才出現在成品路徑。
    func start(settings: RecordingCompressionSettings, audio: RecordingTranscoder.AudioMode, audioBitrate: Int = 128000, qualityPreset: RecordingTranscoder.QualityPreset? = nil) {
        guard !busy, let source else { return }
        systemExportRunning = settings.systemQuality
        busy = true; progress = 0; output = nil; outputDetails = nil
        jobID = UUID()
        let token = jobID
        task = Task {
            defer { busy = false; task = nil; systemExportRunning = false }
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do {
                while captureBusy {
                    message = "等待目前擷取／錄影結束…"
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                try Task.checkCancellation()
                let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true).appendingPathComponent("CompressedVideos", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = source.deletingPathExtension().lastPathComponent
                let destination = folder.appendingPathComponent(name + "_壓縮_" + UUID().uuidString + ".mp4")
                message = "正在壓縮，請保持 App 在前景。"
                _ = try await RecordingTranscoder.compress(url: source, asset: AVURLAsset(url: source),
                    settings: settings, destination: destination, audioMode: audio, audioBitrate: audioBitrate, qualityPreset: qualityPreset) { value in
                        Task { @MainActor in
                            guard self.busy, self.jobID == token else { return }
                            self.progress = max(self.progress, value)
                            if self.captureBusy { self.cancel() }
                        }
                    }
                output = destination
                do { outputDetails = try await RecordingFileDetails.read(destination) }
                catch {
                    message = "檔案已完成，但詳細資訊讀取失敗：" + error.localizedDescription
                    progress = 1
                    return
                }
                progress = 1
                message = "完成，已存入文件共享的 CompressedVideos。"
            } catch {
                message = Task.isCancelled ? "已取消，原檔保留。" : "壓縮失敗：" + error.localizedDescription
                sendlog(message: "[VideoCompression] " + message)
            }
        }
    }

    /// 取消等待或轉碼；Reader／Writer 由共用服務收尾，來源不被替換。
    func cancel() { task?.cancel() }
}
