#if os(iOS) && SCREEN_CAPTURE_KIT_IOS27 && canImport(ScreenCaptureKit) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
import Foundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation
import UIKit

/// 每次擷取獨立持有 delegate；檔案完成與推流狀態互不代替。
@available(iOS 27.0, *)
@MainActor final class ScreenRecordingSession: NSObject, SCRecordingOutputDelegate {
    let id: UUID
    private(set) var terminal = false
    private var output: SCRecordingOutput?
    private let orientation: RecordingOrientationTimeline
    private let policy: RecordingOrientationPolicy
    /// 開錄時固定設定；後續 UI 變更只影響下一次錄影。
    private let compression: RecordingCompressionSettings
    private var nativeFinished = false
    private var correction: Task<Void, Never>?
    private var progress: Task<Void, Never>?
    private var started = false
    private var detached = false
    private let failed: @MainActor (String) -> Void
    init(orientation: RecordingOrientationTimeline, policy: RecordingOrientationPolicy, failed: @escaping @MainActor (String) -> Void) throws {
        self.orientation = orientation
        self.policy = policy
        self.compression = RecordingCompressionSettings.load(from: userDefaults ?? .standard)
        id = try RecordingLibrary.shared.create().id
        self.failed = failed
        super.init()
    }

    /// 建立錄製輸出，並附加到擷取串流；若不支援 MP4 或 H.264/HEVC，會丟出錯誤。
    /// - Parameter stream: SCStream
    /// - Throws: NSError
    func attach(to stream: SCStream) throws {
        do {
            let config = SCRecordingOutputConfiguration()
            guard config.availableOutputFileTypes.contains(.mp4), !config.availableVideoCodecTypes.isEmpty else {
                throw NSError(domain: "LocalRecording", code: 2)
            }
            let preference = RecordingVideoCodec.current
            let resolved = ScreenRecordingCodecSupport.resolve(preference)
            config.outputURL = RecordingLibrary.shared.fileURL(for: id)
            config.outputFileType = .mp4
            config.videoCodecType = resolved.codec
            config.mixesAudioWithMicrophone = true
            if let note = resolved.note {
                sendlog(message: "[RecordingCodec] id=\(id) preference=\(preference.rawValue) \(note)")
            } else {
                sendlog(message: "[RecordingCodec] id=\(id) preference=\(preference.rawValue) codec=\(resolved.codec.rawValue)")
            }
            let output = SCRecordingOutput(configuration: config, delegate: self)
            self.output = output
            try stream.addRecordingOutput(output)
        } catch {
            complete(.failed, message: "無法建立 MP4 錄製輸出（錯誤碼 \((error as NSError).code)）。")
            throw error
        }
    }

    /// 報告錄製狀態。
    private func report(_ phase: RecordingPhase? = nil, message: String? = nil) {
        RecordingLibrary.shared.update(id, phase: phase, duration: output?.recordedDuration.seconds ?? 0,
                                       bytes: (try? RecordingLibrary.shared.fileURL(for: id).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? Int64(output?.recordedFileSize ?? 0), message: message)
        if let phase { sendlog(message: "[Recording] id=\(id) phase=\(phase.rawValue)") }
    }

    /// 立即結束錄製，並丟棄尚未完成的檔案。
    private func complete(_ phase: RecordingPhase, message: String? = nil) {
        guard !terminal else { return }
        terminal = true; progress?.cancel(); progress = nil
        report(phase, message: message)
    }

    /// stopCapture 也會結束錄製；先移除輸出，等待 delegate，而不是以 stop 返回當作檔案完成。
    func detach(from stream: SCStream) {
        guard !detached, let output else { return }
        detached = true
        if !terminal { report(.finishing) }
        do { try stream.removeRecordingOutput(output) }
        catch { report(.finishing, message: "等待系統停止擷取後確認檔案。") }
    }

    /// 等待錄製完成，並在逾時或失敗時保留原始檔案。
    func awaitCompletion() async {
        // 使用 monotonic deadline，避免系統時間變更延長等待；逾時仍保留原檔。
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !terminal && !nativeFinished && ContinuousClock.now < deadline {
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { break }
        }
        if nativeFinished { await correction?.value }
        if !terminal { complete(.interrupted, message: "未收到錄製完成確認，檔案已保留，暫不提供播放或匯出。") }
        output = nil
    }

    /// 錄製開始時，會標示為錄製中並更新錄製檔案資訊。
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self, !self.terminal, !self.started, !self.detached else { return }
            self.started = true
            self.report(.recording)
            self.progress = Task { [weak self] in
                while !Task.isCancelled {
                    self?.report()
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                }
            }
        }
    }

    /// 錄製完成時，會依設定進行方向修正與壓縮，並更新錄製檔案資訊。
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self, !self.terminal, !self.nativeFinished else { return }
            self.nativeFinished = true
            self.progress?.cancel(); self.progress = nil
            if self.policy == .none && !self.compression.enabled {
                sendlog(message: "[RecordingOrientation] id=\(self.id) policy=none skipped")
                self.complete(.ready, message: AppLanguage.localized("recording.orientation.kept"))
                return
            }
            let file = RecordingLibrary.shared.fileURL(for: self.id)
            if self.compression.enabled {
                let original = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                RecordingLibrary.shared.compressionProgress(self.id, original: original)
                self.progress = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        guard let self else { return }
                        let temporary = RecordingTranscoder.temporaryURL(for: file)
                        let bytes = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                        RecordingLibrary.shared.compressionProgress(self.id, output: bytes)
                        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    }
                }
            }
            self.report(.finishing, message: self.compression.enabled ? "正在壓縮並處理影片方向，請保持 App 在前景。" : "正在確認並修正影片方向。")
            self.correction = Task { @MainActor [self] in
                let background = UIApplication.shared.beginBackgroundTask(withName: "RecordingPostprocess") { [weak self] in
                    Task { @MainActor in self?.correction?.cancel() }
                }
                defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
                let startedAt = ContinuousClock.now
                sendlog(message: "[RecordingPostprocess] id=\(self.id) compression=\(self.compression.enabled) systemQuality=\(self.compression.systemQuality) multiPassRequested=\(self.compression.multiPass) hevc=\(self.compression.hevc) mbps=\(self.compression.megabits) longestEdge=\(self.compression.longestEdge) fpsLimit=\(self.compression.fpsLimit)")
                let snapshot = self.orientation.snapshot()
                sendlog(message: "[RecordingOrientation] id=\(self.id) policy=\(self.policy.rawValue) changes=\(snapshot.events.count) missing=\(snapshot.missing) reliable=\(snapshot.reliable)")
                do {
                    let message = try await RecordingOrientationCorrector.correct(url: RecordingLibrary.shared.fileURL(for: self.id), timeline: self.orientation, policy: self.policy, compression: self.compression)
                    sendlog(message: "[RecordingPostprocess] id=\(self.id) elapsed=\(startedAt.duration(to: .now)) \(message)")
                    self.progress?.cancel()
                    if self.compression.enabled {
                        let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                        RecordingLibrary.shared.compressionProgress(self.id, output: bytes, completed: true)
                    }
                    self.complete(.ready, message: message)
                } catch {
                    self.progress?.cancel()
                    if self.compression.enabled { RecordingLibrary.shared.compressionProgress(self.id) }
                    let code = (error as NSError).code
                    sendlog(message: "[RecordingPostprocess] id=\(self.id) elapsed=\(startedAt.duration(to: .now)) failed domain=\((error as NSError).domain) code=\(code) detail=\(error.localizedDescription)")
                    self.complete(.ready, message: "錄後處理未完成：\(error.localizedDescription)（\(code)）。已保留原始錄影，方向或壓縮可能尚未套用。")
                }
            }
        }
    }

    /// 錄製失敗時，仍然保留原始檔案，並標示為失敗。
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        let code = (error as NSError).code
        Task { @MainActor [weak self] in
            guard let self, !self.terminal, !self.nativeFinished else { return }
            let message = "本地錄製失敗（錯誤碼 \(code)）；未完成檔案已保留。"
            self.complete(.failed, message: message)
            self.failed(message)
        }
    }
}

/// ScreenCaptureKit 錄影編碼能力查詢與偏好解析。
@available(iOS 27.0, *)
enum ScreenRecordingCodecSupport {
    /// 執行期可用的編碼清單（惰性取一次）。
    static let availableVideoCodecs: [AVVideoCodecType] = SCRecordingOutputConfiguration().availableVideoCodecTypes

    /// 使用者選擇的編碼是否可用；`auto` 一律視為可用。
    static func isAvailable(_ codec: RecordingVideoCodec) -> Bool {
        guard let id = codec.codecIdentifier else { return true }
        return availableVideoCodecs.contains { $0.rawValue == id }
    }

    /// 依偏好挑選實際編碼；不支援時退回相容選項並附提示。
    static func resolve(_ preference: RecordingVideoCodec) -> (codec: AVVideoCodecType, note: String?) {
        let fallback = availableVideoCodecs.first { $0 == .h264 } ?? availableVideoCodecs.first
        if preference == .auto {
            if let hevc = availableVideoCodecs.first(where: { $0 == .hevc }) { return (hevc, nil) }
            if let fallback { return (fallback, nil) }
        } else if let id = preference.codecIdentifier,
                  let match = availableVideoCodecs.first(where: { $0.rawValue == id }) {
            return (match, nil)
        } else if let fallback {
            return (fallback, "不支援 \(preference.title)，已改用 \(name(fallback))。")
        }
        return (.h264, nil)
    }

    private static func name(_ codec: AVVideoCodecType) -> String {
        switch codec.rawValue {
        case "avc1": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "av01": return "AV1"
        default: return codec.rawValue
        }
    }
}
#endif
