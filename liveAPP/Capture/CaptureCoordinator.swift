import Foundation
import SwiftUI
#if os(iOS)
import AVFoundation
import UIKit
#if SCREEN_CAPTURE_KIT_IOS27 && canImport(ScreenCaptureKit) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
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
    /// ScreenCaptureKit 在此建置／裝置不可用的原因；nil 表示可用。
    /// 由「最特定」排到「最一般」，讓 UI 能直接顯示為何灰掉。
    var screenCaptureUnavailableReason: String? {
        #if targetEnvironment(simulator)
        return "螢幕擷取僅支援實機（模擬器不支援）"
        #elseif targetEnvironment(macCatalyst)
        return "Mac Catalyst 不支援此擷取來源"
        #elseif !SCREEN_CAPTURE_KIT_IOS27
        return "此建置未啟用 ScreenCaptureKit（需以 Xcode 27／iOS 27 SDK 建置）"
        #elseif !canImport(ScreenCaptureKit)
        return "此 SDK 不含 ScreenCaptureKit 模組"
        #else
        if #available(iOS 27.0, *) {
            return SCContentSharingPicker.shared.isAvailable ? nil : "此裝置目前無法螢幕錄製（系統限制、受管理裝置或未允許）"
        }
        return "需要 iOS 27 或以上（目前 \(UIDevice.current.systemVersion)）"
        #endif
    }
    var screenCaptureSupported: Bool { screenCaptureUnavailableReason == nil }
    func startScreenCapture(url: String, key: String, mode: CaptureWorkMode = .stream) {
        guard !isBusy else { return }
        guard screenCaptureSupported else { errorMessage = "ScreenCaptureKit 需要 iOS 27 與支援此功能的 App 版本。"; return }
        guard mode.accepts(endpoint: url, key: key) else {
            errorMessage = "請先填寫有效的 RTMP 網址與串流金鑰。"; return
        }
        do { lease = try CaptureLease.acquire() }
        catch { errorMessage = error.localizedDescription; return }
        #if SCREEN_CAPTURE_KIT_IOS27 && canImport(ScreenCaptureKit) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
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
    @AppStorage("captureWorkMode", store: userDefaults) private var workMode = CaptureWorkMode.stream.rawValue
    @ObservedObject private var library = RecordingLibrary.shared
    @State private var anotherCapture = false
    @State private var showingRecordings = false

    private var isScreenCaptureKit: Bool { backend == CaptureBackend.screenCaptureKit.rawValue }
    private var selectedWorkMode: CaptureWorkMode { CaptureWorkMode(rawValue: workMode) ?? .stream }
    private var controlsDisabled: Bool { capture.isBusy || anotherCapture }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            backendPicker
            if isScreenCaptureKit { screenCaptureKitOptions }
            Button("本地錄影") { showingRecordings = true }
            if let message = capture.errorMessage {
                Label(message, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .sheet(isPresented: $showingRecordings) { RecordingLibraryView() }
        .task { await watchCaptureLease() }
    }

    /// 擷取來源選擇；不可用時附上原因，方便直接從畫面判斷為何變灰。
    private var backendPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("螢幕擷取方式", selection: $backend) {
                Text("ReplayKit").tag(CaptureBackend.replayKit.rawValue)
                Text("ScreenCaptureKit（測試中）").tag(CaptureBackend.screenCaptureKit.rawValue)
                    .disabled(!capture.screenCaptureSupported)
            }
            .disabled(controlsDisabled)
            if let reason = capture.screenCaptureUnavailableReason {
                Label(reason, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if anotherCapture {
                Label("偵測到其他程序正在使用螢幕擷取，請先停止後再切換來源。", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if capture.isBusy {
                Label("擷取進行中，停止後才能切換來源。", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// ScreenCaptureKit（測試版）的工作模式、狀態與停止。
    private var screenCaptureKitOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("測試版使用系統全螢幕擷取；自訂 GPU 畫布、浮水印與進階音訊處理請改用 ReplayKit。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("工作模式", selection: $workMode) {
                ForEach(CaptureWorkMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .disabled(controlsDisabled)
            if selectedWorkMode.wantsRecording {
                Text("本地錄影保存系統擷取的畫面與聲音，不含浮水印、進階音訊處理或推流音量調整；只錄製不需 RTMP 設定。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            statusLine
            if capture.isBusy {
                Button("停止擷取") { capture.stop() }
                    .disabled(capture.phase == .stopping)
            }
        }
    }

    /// 擷取階段／推流／錄製進度合併為一行。
    private var statusLine: some View {
        HStack(spacing: 8) {
            Text(capture.phase.title)
            if capture.isPublishing { Text("推流中").foregroundStyle(.green) }
            if let item = library.recordings.first, capture.isBusy, !item.phase.isTerminal {
                Text("· \(item.phase.title) \(Int(item.duration)) 秒 · \(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    /// 每秒偵測是否有其他程序持有擷取鎖，避免兩個來源同時啟動。
    private func watchCaptureLease() async {
        while !Task.isCancelled {
            if !capture.isBusy {
                do { let lease = try CaptureLease.acquire(); withExtendedLifetime(lease) {}; anotherCapture = false }
                catch { anotherCapture = true }
            }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
        }
    }
}
#endif
