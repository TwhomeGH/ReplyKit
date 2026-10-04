import Foundation
import SwiftUI
#if os(iOS)
import AVFoundation
#if SCREEN_CAPTURE_KIT_IOS27 && canImport(ScreenCaptureKit) && !targetEnvironment(macCatalyst)
import ScreenCaptureKit
#endif

@MainActor protocol CaptureDriver: AnyObject {
    func present()
    func stop() async
}

@MainActor final class CaptureCoordinator: ObservableObject {
    static let shared = CaptureCoordinator()
    @Published private(set) var phase: CapturePhase = .idle
    @Published var errorMessage: String?
    @Published private(set) var isPublishing = false
    private var lease: CaptureLease?
    private var driver: (any CaptureDriver)?
    var isBusy: Bool { phase != .idle }
    var screenCaptureSupported: Bool {
        #if SCREEN_CAPTURE_KIT_IOS27 && canImport(ScreenCaptureKit) && !targetEnvironment(macCatalyst)
        if #available(iOS 27.0, *) { return SCContentSharingPicker.shared.isAvailable }
        #endif
        return false
    }
    func startScreenCapture(url: String, key: String, mode: CaptureWorkMode = .stream) {
        guard !isBusy else { return }
        guard screenCaptureSupported else { errorMessage = "ScreenCaptureKit 需要 iOS 27 與支援此功能的 App 版本。"; return }
        guard mode.accepts(endpoint: url, key: key) else {
            errorMessage = "請先填寫有效的 RTMP 網址與串流金鑰。"; return
        }
        do { lease = try CaptureLease.acquire() }
        catch { errorMessage = error.localizedDescription; return }
        #if SCREEN_CAPTURE_KIT_IOS27 && canImport(ScreenCaptureKit) && !targetEnvironment(macCatalyst)
        if #available(iOS 27.0, *) {
            errorMessage = nil
            phase = .selecting
            let source = ScreenCaptureSource(url: url, key: key, mode: mode, publishingChanged: { [weak self] active in
                guard let self, self.isPublishing != active else { return }
                self.isPublishing = active
                if active { SocketServer.shared.StreamStarting() }
                else { SocketServer.shared.StreamStatusChanged(isLive: false, message: nil) }
            }) { [weak self] phase, message in
                guard let self else { return }
                self.phase = phase
                if let message { self.errorMessage = message }
                if phase == .idle {
                    self.driver = nil; self.lease = nil
                }
            }
            driver = source; source.present(); return
        }
        #endif
        lease = nil
    }
    func stop() { guard phase != .stopping else { return }; Task { await driver?.stop() } }
}

@MainActor struct CaptureSelectionView: View {
    @AppStorage("captureBackend", store: userDefaults) private var backend = CaptureBackend.replayKit.rawValue
    @ObservedObject private var capture = CaptureCoordinator.shared
    @State private var anotherCapture = false
    @AppStorage("captureWorkMode", store: userDefaults) private var workMode = CaptureWorkMode.stream.rawValue
    @ObservedObject private var library = RecordingLibrary.shared
    @State private var showingRecordings = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("螢幕擷取方式", selection: $backend) {
                Text("ReplayKit").tag(CaptureBackend.replayKit.rawValue)
                Text("ScreenCaptureKit（測試中）").tag(CaptureBackend.screenCaptureKit.rawValue)
                    .disabled(!capture.screenCaptureSupported)
            }
            .disabled(capture.isBusy || anotherCapture)
            if !capture.screenCaptureSupported { Text("ScreenCaptureKit 需要 iOS 27 及支援此功能的 App 版本。").font(.caption).foregroundStyle(.secondary) }
            if backend == CaptureBackend.screenCaptureKit.rawValue {
                Text("測試版使用系統全螢幕擷取。自訂 GPU 畫布、直播浮水印與進階音訊處理目前請使用 ReplayKit。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("工作模式", selection: $workMode) {
                    ForEach(CaptureWorkMode.allCases) { Text($0.title).tag($0.rawValue) }
                }.disabled(capture.isBusy || anotherCapture)
                if (CaptureWorkMode(rawValue: workMode) ?? .stream).wantsRecording {
                    Text("本地錄影保存系統擷取的畫面與聲音，不包含直播浮水印、進階音訊處理或推流音量調整。只錄製不需 RTMP 設定。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(capture.phase.title)
                if capture.isPublishing { Text("推流中").font(.caption) }
                if capture.isBusy, let item = library.recordings.first, !item.phase.isTerminal {
                    Text("\(item.phase.title) · \(Int(item.duration)) 秒 · \(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))")
                        .font(.caption)
                }
                if capture.isBusy { Button("停止擷取") { capture.stop() }.disabled(capture.phase == .stopping) }
            }
            Button("本地錄影") { showingRecordings = true }
            if let message = capture.errorMessage { Text(message).foregroundStyle(.red).font(.caption) }
        }
        .padding(.horizontal)
        .sheet(isPresented: $showingRecordings) { RecordingLibraryView() }
        .task {
            while !Task.isCancelled {
                if !capture.isBusy {
                    do { let lease = try CaptureLease.acquire(); withExtendedLifetime(lease) {}; anotherCapture = false }
                    catch { anotherCapture = true }
                }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
            }
        }
    }
}
#endif
