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
    private var nativeFinished = false
    private var correction: Task<Void, Never>?
    private var progress: Task<Void, Never>?
    private var started = false
    private var detached = false
    private let failed: @MainActor (String) -> Void
    init(orientation: RecordingOrientationTimeline, policy: RecordingOrientationPolicy, failed: @escaping @MainActor (String) -> Void) throws {
        self.orientation = orientation
        self.policy = policy
        id = try RecordingLibrary.shared.create().id
        self.failed = failed
        super.init()
    }
    func attach(to stream: SCStream) throws {
        do {
            let config = SCRecordingOutputConfiguration()
            guard config.availableOutputFileTypes.contains(.mp4), config.availableVideoCodecTypes.contains(.h264) else {
                throw NSError(domain: "LocalRecording", code: 2)
            }
            config.outputURL = RecordingLibrary.shared.fileURL(for: id)
            config.outputFileType = .mp4
            config.videoCodecType = .h264
            config.mixesAudioWithMicrophone = true
            let output = SCRecordingOutput(configuration: config, delegate: self)
            self.output = output
            try stream.addRecordingOutput(output)
        } catch {
            complete(.failed, message: "無法建立 MP4 錄製輸出（錯誤碼 \((error as NSError).code)）。")
            throw error
        }
    }
    private func report(_ phase: RecordingPhase? = nil, message: String? = nil) {
        RecordingLibrary.shared.update(id, phase: phase, duration: output?.recordedDuration.seconds ?? 0,
                                       bytes: (try? RecordingLibrary.shared.fileURL(for: id).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? Int64(output?.recordedFileSize ?? 0), message: message)
        if let phase { sendlog(message: "[Recording] id=\(id) phase=\(phase.rawValue)") }
    }
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
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self, !self.terminal, !self.nativeFinished else { return }
            self.nativeFinished = true
            self.progress?.cancel(); self.progress = nil
            if self.policy == .none {
                sendlog(message: "[RecordingOrientation] id=\(self.id) policy=none skipped")
                self.complete(.ready, message: AppLanguage.localized("recording.orientation.kept"))
                return
            }
            self.report(.finishing, message: "正在確認並修正影片方向。")
            self.correction = Task { @MainActor [self] in
                let background = UIApplication.shared.beginBackgroundTask(withName: "RecordingOrientation") { [weak self] in
                    Task { @MainActor in self?.correction?.cancel() }
                }
                defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
                let snapshot = orientation.snapshot()
                sendlog(message: "[RecordingOrientation] id=\(id) policy=\(policy.rawValue) changes=\(snapshot.events.count) missing=\(snapshot.missing) reliable=\(snapshot.reliable)")
                do {
                    let message = try await RecordingOrientationCorrector.correct(url: RecordingLibrary.shared.fileURL(for: id), timeline: orientation, policy: policy)
                    sendlog(message: "[RecordingOrientation] id=\(id) \(message)")
                    complete(.ready, message: message)
                } catch {
                    let code = (error as NSError).code
                    sendlog(message: "[RecordingOrientation] id=\(id) correctionFailed=\(code)")
                    complete(.ready, message: "方向修正未完成（錯誤碼 \(code)），已保留原始錄影，方向可能尚未轉正。")
                }
            }
        }
    }
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
#endif
