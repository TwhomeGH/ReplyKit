#if os(iOS) && SCREEN_CAPTURE_KIT_IOS27 && canImport(ScreenCaptureKit) && !targetEnvironment(macCatalyst)
import Foundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation
import HaishinKit
import RTMPHaishinKit
import VideoToolbox

@available(iOS 27.0, *)
private struct SelectedCaptureFilter: @unchecked Sendable { let filter: SCContentFilter }

private struct CapturedSample: @unchecked Sendable { let buffer: CMSampleBuffer }

/// 回呼只交付樣本，消費端各自保序；總排隊預算 14 MiB，不含消費端/GPU/編碼器。
@available(iOS 27.0, *)
private final class ScreenSamplePump: NSObject, SCStreamOutput, @unchecked Sendable {
    let video = CaptureMailbox<CapturedSample>(budget: 12 * 1024 * 1024)
    let audio = CaptureMailbox<CapturedSample>(budget: 1024 * 1024)
    let mic = CaptureMailbox<CapturedSample>(budget: 1024 * 1024)
    private var workers: [Task<Void, Never>] = []
    init(mixer: MediaMixer) {
        super.init()
        for (queue, track) in [(video, UInt8(0)), (audio, UInt8(0)), (mic, UInt8(1))] {
            workers.append(Task {
                for await sample in queue.stream() {
                    guard !Task.isCancelled else { break }
                    await mixer.append(sample.buffer, track: track)
                }
            })
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let sample = CapturedSample(buffer: sampleBuffer)
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete,
                  let image = sampleBuffer.imageBuffer else { return }
            video.offer(sample, bytes: CVPixelBufferGetDataSize(image))
        case .audio: audio.offer(sample, bytes: CMSampleBufferGetTotalSampleSize(sampleBuffer))
        case .microphone: mic.offer(sample, bytes: CMSampleBufferGetTotalSampleSize(sampleBuffer))
        @unknown default: break
        }
    }
    func finish() async {
        video.finish(); audio.finish(); mic.finish()
        for worker in workers { worker.cancel() }
        for worker in workers { await worker.value }
        workers.removeAll()
    }
}

@available(iOS 27.0, *)
@MainActor final class ScreenCaptureSource: NSObject, CaptureDriver,
    SCContentSharingPickerObserver, SCStreamDelegate {
    private let url: String
    private let key: String
    private let update: @MainActor (CapturePhase, String?) -> Void
    private var state = CaptureSessionState()
    private let mode: CaptureWorkMode
    private let publishingChanged: @MainActor (Bool) -> Void
    private var pipeline: CaptureMediaPipeline?
    private var recording: ScreenRecordingSession?
    private var publishingTask: Task<Void, Never>?
    private var streamingViable = false
    private var cleaningPublishing = false
    private var connection: RTMPConnection?
    private var output: RTMPStream?
    private var capture: SCStream?
    private var pump: ScreenSamplePump?
    private var operation: Task<Void, Never>?
    private var diagnostics: Task<Void, Never>?
    private var ownsAudioSession = false
    private var priorCategory: AVAudioSession.Category?
    private var priorMode: AVAudioSession.Mode?
    private var priorOptions: AVAudioSession.CategoryOptions = []
    private let sampleQueue = DispatchQueue(label: "capture.screencapturekit.samples", qos: .userInitiated)
    init(url: String, key: String, mode: CaptureWorkMode,
         publishingChanged: @escaping @MainActor (Bool) -> Void,
         update: @escaping @MainActor (CapturePhase, String?) -> Void) {
        self.url = url; self.key = key; self.mode = mode
        self.publishingChanged = publishingChanged; self.update = update
    }
    func present() {
        guard state.begin() != nil else { return }
        let picker = SCContentSharingPicker.shared
        var settings = SCContentSharingPickerConfiguration()
        settings.showsMicrophoneControl = true
        picker.defaultConfiguration = settings
        picker.add(self); picker.isActive = true; picker.present()
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self, self.state.phase == .selecting else { return }
            await self.stop()
        }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let code = (error as NSError).code
        Task { @MainActor [weak self] in await self?.finish(message: "無法開啟畫面分享選擇器（錯誤碼 \(code)）。") }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let selection = SelectedCaptureFilter(filter: filter)
        Task { @MainActor [weak self] in self?.selected(selection.filter) }
    }
    private func selected(_ filter: SCContentFilter) {
        if state.phase == .streaming {
            Task { await finish(message: "分享選項已變更，請重新開始擷取以套用新選擇。") }
            return
        }
        guard let token = state.id, state.transition(.starting, for: token) else { return }
        update(.starting, nil)
        operation = Task { [self] in
            do { try await start(filter: filter, token: token) }
            catch is CancellationError {
                if state.phase != .stopping { Task { await self.finish(message: nil) } }
            }
            catch {
                // 不輸出可能包含串流金鑰的底層錯誤描述。
                let code = (error as NSError).code
                Task { await self.finish(message: "啟動擷取失敗（錯誤碼 \(code)），請檢查授權與擷取設定。") }
            }
        }
    }
    private func start(filter: SCContentFilter, token: UUID) async throws {
        let defaults = userDefaults ?? .standard
        let width = max(2, defaults.integer(forKey: "odstW") > 0 ? defaults.integer(forKey: "odstW") : 1920)
        let height = max(2, defaults.integer(forKey: "odstH") > 0 ? defaults.integer(forKey: "odstH") : 1080)
        let size = CGSize(width: min(3840, width / 2 * 2), height: min(2160, height / 2 * 2))
        CaptureAudioOwnership.shared.begin()
        if filter.isMicrophoneEnabled {
            let session = AVAudioSession.sharedInstance()
            priorCategory = session.category; priorMode = session.mode; priorOptions = session.categoryOptions
            ownsAudioSession = true
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
            try session.setActive(true)
        }
        let config = SCStreamConfiguration()
        config.width = Int(size.width); config.height = Int(size.height)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 3
        config.capturesAudio = true
        config.captureMicrophone = filter.isMicrophoneEnabled
        config.scalesToFit = true
        config.preservesAspectRatio = true
        let source = SCStream(filter: filter, configuration: config, delegate: self)
        capture = source
        streamingViable = mode.wantsStreaming
        if mode.wantsRecording {
            do {
                let recording = try ScreenRecordingSession { [weak self] message in
                    guard let self, self.state.phase != .stopping else { return }
                    if let capture = self.capture { self.recording?.detach(from: capture) }
                    self.update(self.state.phase, message)
                    if !self.streamingViable { Task { await self.finish(message: message) } }
                }
                self.recording = recording
                try recording.attach(to: source)
            } catch {
                guard mode.wantsStreaming else { throw error }
                update(.starting, "本地錄製無法啟動；將繼續嘗試推流。")
            }
        }
        if mode.wantsStreaming {
            do { try await preparePublishing(source: source, filter: filter, size: size) }
            catch is CancellationError { throw CancellationError() }
            catch {
                streamingViable = false
                await stopPublishing()
                guard let recording, !recording.terminal else { throw error }
                update(.starting, "推流管線無法建立；將繼續本地錄製。")
            }
        }
        try Task.checkCancellation()
        try await source.startCapture()
        try Task.checkCancellation()
        guard state.transition(.streaming, for: token) else { throw CancellationError() }
        update(.streaming, nil)
        if streamingViable {
            publishingTask = Task { [self] in
                do { try await startPublishing() }
                catch is CancellationError { }
                catch {
                    let code = (error as NSError).code
                    // 清理工作另開 Task，避免等待自己。
                    Task { await self.publishingFailed("推流啟動失敗（錯誤碼 \(code)）。") }
                }
            }
        }
        diagnostics = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let queues = self.pump.map { "video{\($0.video.summary)} audio{\($0.audio.summary)} mic{\($0.mic.summary)}" } ?? "sampleQueues=none"
                sendlog(message: "[CaptureSource] backend=screenCaptureKit session=\(token) mode=\(self.mode.rawValue) phase=\(self.state.phase.rawValue) \(queues)")
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
    }
    private func preparePublishing(source: SCStream, filter: SCContentFilter, size: CGSize) async throws {
        let defaults = userDefaults ?? .standard
        let pipeline = CaptureMediaPipeline()
        self.pipeline = pipeline
        let conn = RTMPConnection()
        let stream = RTMPStream(connection: conn)
        connection = conn; output = stream
        await conn.setOnLog { event in
            // 只轉送管線快照；其他 RTMP 事件可能包含推流路徑／金鑰。
            if event.message.hasPrefix("VideoQueue") {
                sendlog(message: "[ScreenCaptureKit] \(event.message) \(event.detail ?? "")")
            }
        }
        try Task.checkCancellation()
        var video = await stream.videoSettings
        video.videoSize = size
        video.bitRate = max(100_000, defaults.object(forKey: "bitRate") as? Int ?? 6_000_000)
        video.maxKeyFrameIntervalDuration = Int32(max(0, min(60, defaults.object(forKey: "KeyFrameInterval") as? Int ?? 2)))
        video.allowFrameReordering = false
        video.scalingMode = .letterbox
        video.expectedFrameRate = 60
        video.profileLevel = kVTProfileLevel_H264_High_AutoLevel as String
        switch defaults.integer(forKey: "BitRateMode") {
        case 1: video.bitRateMode = .constant
        case 2: video.bitRateMode = .variable
        default: video.bitRateMode = .average
        }
        try await stream.setVideoSettings(video)
        await stream.setBitRateStrategy(StreamVideoAdaptiveBitRateStrategy(mamimumVideoBitrate: video.bitRate))
        await conn.setReconnectEnabled(true)
        await conn.setOnReconnectStateChanged { [weak self] reconnect in
            if case .exhausted = reconnect {
                Task { @MainActor in await self?.publishingFailed("網路重連次數已達上限，推流已停止。") }
            }
        }
        var audio = await stream.audioSettings
        audio.bitRate = AudioCodecSettings.recommendedRtmpBitrate
        audio.format = AudioCodecSettings.recommendedRtmpFormat
        try await stream.setAudioSettings(audio)
        var mixing = CaptureMediaPipeline.audioSettings(from: await pipeline.mixer.audioMixerSettings, microphone: filter.isMicrophoneEnabled)
        mixing.tracks[0]?.volume = Float(defaults.object(forKey: "appVolume") as? Double ?? 1)
        mixing.tracks[1]?.volume = Float(defaults.object(forKey: "micVolume") as? Double ?? 1)
        await pipeline.mixer.setAudioMixerSettings(mixing)
        var videoMixing = await pipeline.mixer.videoMixerSettings
        videoMixing.mode = .passthrough
        await pipeline.mixer.setVideoMixerSettings(videoMixing)
        await pipeline.mixer.addOutput(stream)
        await pipeline.mixer.startRunning()
        try Task.checkCancellation()
        let pump = ScreenSamplePump(mixer: pipeline.mixer)
        self.pump = pump
        try source.addStreamOutput(pump, type: .screen, sampleHandlerQueue: sampleQueue)
        try source.addStreamOutput(pump, type: .audio, sampleHandlerQueue: sampleQueue)
        if filter.isMicrophoneEnabled { try source.addStreamOutput(pump, type: .microphone, sampleHandlerQueue: sampleQueue) }
    }
    private func startPublishing() async throws {
        guard let conn = connection, let stream = output else { throw CancellationError() }
        try Task.checkCancellation()
        _ = try await conn.connect(url)
        try Task.checkCancellation()
        _ = try await stream.publish(key)
        try Task.checkCancellation()
        publishingChanged(true)
    }
    private func publishingFailed(_ message: String) async {
        guard state.id != nil, state.phase != .stopping, !cleaningPublishing else { return }
        cleaningPublishing = true
        streamingViable = false
        publishingTask?.cancel()
        await publishingTask?.value; publishingTask = nil
        await stopPublishing()
        cleaningPublishing = false
        guard state.phase != .stopping else { return }
        if let recording, !recording.terminal {
            update(state.phase, message + " 本地錄製繼續。")
        } else { await finish(message: message) }
    }
    private func stopPublishing() async {
        publishingChanged(false)
        if let connection { await connection.setReconnectEnabled(false) }
        if let pump, let capture {
            try? capture.removeStreamOutput(pump, type: .screen)
            try? capture.removeStreamOutput(pump, type: .audio)
            try? capture.removeStreamOutput(pump, type: .microphone)
        }
        await pump?.finish(); pump = nil
        if let output {
            _ = try? await output.close()
            await pipeline?.mixer.removeOutput(output)
        }
        await pipeline?.mixer.stopRunning()
        _ = try? await connection?.close()
        output = nil; connection = nil; pipeline = nil
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let identity = ObjectIdentifier(stream)
        let code = (error as NSError).code
        Task { @MainActor [weak self] in
            guard let self, let current = self.capture, ObjectIdentifier(current) == identity,
                  self.state.phase != .stopping else { return }
            await self.finish(message: "系統已停止畫面分享（錯誤碼 \(code)）。")
        }
    }
    func stop() async { await finish(message: nil) }
    private func finish(message: String?) async {
        guard let token = state.id, state.phase != .stopping else { return }
        state.stopping(); update(.stopping, nil)
        operation?.cancel(); diagnostics?.cancel()
        // 等待啟動中的 await 結束，避免停止後又建立擷取或 RTMP 連線。
        await operation?.value; operation = nil
        publishingTask?.cancel()
        await publishingTask?.value; publishingTask = nil
        // 若輸出失敗清理已在進行，讓其結束，避免對 RTMP/Mixer 重複 close。
        while cleaningPublishing { try? await Task.sleep(nanoseconds: 10_000_000) }
        if let capture {
            recording?.detach(from: capture)
            try? await capture.stopCapture()
        }
        await recording?.awaitCompletion(); recording = nil
        await stopPublishing(); capture = nil
        let picker = SCContentSharingPicker.shared
        picker.remove(self); picker.isActive = false
        if ownsAudioSession {
            let session = AVAudioSession.sharedInstance()
            if let priorCategory, let priorMode { try? session.setCategory(priorCategory, mode: priorMode, options: priorOptions) }
            ownsAudioSession = false
        }
        CaptureAudioOwnership.shared.end()
        state.finish(token); update(.idle, message)
    }
}
#endif
