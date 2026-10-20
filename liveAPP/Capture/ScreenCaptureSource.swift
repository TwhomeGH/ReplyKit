#if os(iOS) && SCREEN_CAPTURE_KIT_IOS27 && canImport(ScreenCaptureKit) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
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
    private var loggedFrameSize = CGSize.zero
    init(mixer: MediaMixer, probe: ScreenAudioProbe, rotateLeft: Bool,
         canvas: CGSize? = nil, fills: Bool = false) throws {
        let compositor = try ScreenStreamVideoRotator(rotateLeft: rotateLeft, overlay: ScreenOverlayComposer(),
                                                      canvas: canvas, fills: fills)
        super.init()
        for (queue, track, isVideo) in [(video, UInt8(0), true), (audio, UInt8(0), false), (mic, UInt8(1), false)] {
            workers.append(Task {
                var rotationFailures = 0
                for await sample in queue.stream() {
                    guard !Task.isCancelled else { break }
                    if isVideo {
                        do { await mixer.append(try compositor.rotate(sample.buffer), track: track) }
                        catch {
                            rotationFailures += 1
                            if rotationFailures == 1 || rotationFailures % 300 == 0 {
                                sendlog(message: "[CaptureVideoRotation] dropped=\(rotationFailures) error=\(error)")
                            }
                        }
                    } else {
                        probe.observe(sample.buffer, track: track)
                        await mixer.append(sample.buffer, track: track)
                    }
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
            let frameSize = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
            if frameSize != loggedFrameSize {
                loggedFrameSize = frameSize
                sendlog(message: "[CaptureFrame] size=\(Int(frameSize.width))x\(Int(frameSize.height))")
            }
            video.offer(sample, bytes: CVPixelBufferGetDataSize(image))
        case .audio: audio.offer(sample, bytes: CMSampleBufferGetTotalSampleSize(sampleBuffer))
        case .microphone: mic.offer(sample, bytes: CMSampleBufferGetTotalSampleSize(sampleBuffer))
        @unknown default: break
        }
    }
    func finish() async {
        // 擷取停止後排空已接受的尾端樣本，避免清理階段額外截斷音訊。
        video.finish(discardPending: false)
        audio.finish(discardPending: false)
        mic.finish(discardPending: false)
        for worker in workers { await worker.value }
        workers.removeAll()
    }
}

@available(iOS 27.0, *)
@MainActor final class ScreenCaptureSource: NSObject, CaptureDriver,
    SCContentSharingPickerObserver, SCStreamDelegate {

    /// 來源URL
    private let url: String
    /// 來源Key
    private let key: String
    private let update: @MainActor (CapturePhase, String?) -> Void
    private var state = CaptureSessionState()
    private let mode: CaptureWorkMode
    private let recordingPolicy: RecordingOrientationPolicy
    private let publishingChanged: @MainActor (Bool) -> Void
    private var pipeline: CaptureMediaPipeline?
    private let directRecordingEnabled = (userDefaults ?? .standard).bool(forKey: "directRecordingEnabled")
    private var recordingSink: SegmentedRecordingSink?
    private var directRecordingFailed = false
    private var mediaPrepared = false
    private var volumeUpdates: Task<Void, Never>?
    private var hasRecording: Bool {
        (recording != nil && recording?.terminal == false) || (mediaPrepared && recordingSink != nil && !directRecordingFailed)
    }
    private var audioProbe: ScreenAudioProbe?
    private var streamDiagnosticsProbe: StreamDiagnosticsProbe?
    private var telemetry = CaptureStreamTelemetry()
    private let telemetryChanged: @MainActor (CaptureStreamTelemetry) -> Void
    private var recording: ScreenRecordingSession?
    private var recordingOrientation: ScreenRecordingOrientationObserver?
    private var publishingTask: Task<Void, Never>?
    private var streamingViable = false
    private var startupStage = "idle"
    private var publishingStage = "idle"
    private var cleaningPublishing = false
    private var connection: RTMPConnection?
    private var output: RTMPStream?
    private var capture: SCStream?
    private var pump: ScreenSamplePump?
    private var operation: Task<Void, Never>?
    private var diagnostics: Task<Void, Never>?
    private var ownsAudioSession = false
    private var audioObservers: [NSObjectProtocol] = []
    private var priorCategory: AVAudioSession.Category?
    private var priorMode: AVAudioSession.Mode?
    private var priorOptions: AVAudioSession.CategoryOptions = []
    private let sampleQueue = DispatchQueue(label: "capture.screencapturekit.samples", qos: .userInitiated)
    init(url: String, key: String, mode: CaptureWorkMode,
         publishingChanged: @escaping @MainActor (Bool) -> Void,
         telemetryChanged: @escaping @MainActor (CaptureStreamTelemetry) -> Void,
         update: @escaping @MainActor (CapturePhase, String?) -> Void) {
        self.url = url; self.key = key; self.mode = mode
        recordingPolicy = RecordingOrientationPolicy(rawValue: userDefaults?.string(forKey: "recordingOrientationPolicy") ?? "") ?? .automatic
        self.publishingChanged = publishingChanged; self.update = update
        self.telemetryChanged = telemetryChanged
    }

    func present() {
        guard state.begin() != nil else { return }
        startupStage = "picker.present"
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
        Task { @MainActor [weak self] in
            self?.logFailure(error, stage: "picker.present")
            await self?.finish(message: "無法開啟畫面分享選擇器（錯誤碼 \(code)）。")
        }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let selection = SelectedCaptureFilter(filter: filter)
        Task { @MainActor [weak self] in self?.selected(selection.filter) }
    }
    /// 接收使用者選取的分享內容，建立可取消的啟動工作並統一處理啟動失敗。
    /// 已在擷取時變更選擇會結束本次工作，要求重新開始以套用新內容。
    /// - Parameter filter: 系統分享選擇器提供的擷取內容與麥克風選項。
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
                logFailure(error, stage: startupStage)
                let code = (error as NSError).code
                Task { await self.finish(message: "啟動擷取失敗（錯誤碼 \(code)），請檢查授權與擷取設定。") }
            }
        }
    }
    /// 準備音訊、SCStream 與所選模式的錄製／推流管線，啟動擷取及診斷回報。
    /// RTMP 連線由獨立 publishingTask 執行，因此本函式完成不表示推流成功。
    /// - Parameters:
    ///   - filter: 本次分享內容與麥克風選項。
    ///   - token: 本次擷取識別碼，用於狀態轉移與日誌關聯。
    /// - Throws: 無法繼續擷取的初始化錯誤、系統啟動錯誤或工作取消。
    ///   呼叫端負責呼叫 finish(message:) 收回已建立的資源。
    private func start(filter: SCContentFilter, token: UUID) async throws {
        let defaults = userDefaults ?? .standard
        let width = max(2, defaults.integer(forKey: "odstW") > 0 ? defaults.integer(forKey: "odstW") : 1920)
        let height = max(2, defaults.integer(forKey: "odstH") > 0 ? defaults.integer(forKey: "odstH") : 1080)
        let size = CGSize(width: min(3840, width / 2 * 2), height: min(2160, height / 2 * 2))
        CaptureAudioOwnership.shared.begin()
        observeAudioSession(token: token)
        logAudioSession("capture.begin")
        if filter.isMicrophoneEnabled {
            let session = AVAudioSession.sharedInstance()
            priorCategory = session.category; priorMode = session.mode; priorOptions = session.categoryOptions
            ownsAudioSession = true
            startupStage = "audioSession.configure"
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            logAudioSession("capture.audioActivated")
        }
        let config = SCStreamConfiguration()
        // SC 擷取緩衝的寬高與輸出設定是轉置的（與 ReplayKit 相同）：左轉時以「轉置」尺寸擷取，
        // 旋轉後剛好對上輸出畫布 size（否則來源是橫的、畫面內容被塞成直的）。
        let rotateLeft = defaults.object(forKey: "screenStreamRotateLeft") as? Bool ?? true
        if rotateLeft {
            config.width = Int(size.height); config.height = Int(size.width)
        } else {
            config.width = Int(size.width); config.height = Int(size.height)
        }
        config.capturesAudio = true
        // 以下皆為 macOS/macCatalyst 專用（iOS 標記為不可用），iOS 一概不設定：
        // pixelFormat / minimumFrameInterval / queueDepth / captureMicrophone /
        // scalesToFit / preservesAspectRatio。iOS 使用系統預設值；麥克風改由
        // SCContentSharingPickerConfiguration.showsMicrophoneControl 控制。
        let source = SCStream(filter: filter, configuration: config, delegate: self)
        capture = source
        streamingViable = mode.wantsStreaming
        if mode.wantsRecording && !directRecordingEnabled {
            do {
                startupStage = "recording.attach"
                let observer = ScreenRecordingOrientationObserver()
                recordingOrientation = observer
                try source.addStreamOutput(observer, type: .screen, sampleHandlerQueue: sampleQueue)
                let recording = try ScreenRecordingSession(orientation: observer.timeline, policy: recordingPolicy) { [weak self] message in
                    guard let self, self.state.phase != .stopping else { return }
                    if let capture = self.capture { self.recording?.detach(from: capture) }
                    self.update(self.state.phase, message)
                    if !self.streamingViable { Task { await self.finish(message: message) } }
                }
                self.recording = recording
                try recording.attach(to: source)
            } catch {
                logFailure(error, stage: "recording.attach")
                guard mode.wantsStreaming else { throw error }
                update(.starting, "本地錄製無法啟動；將繼續嘗試推流。")
            }
        }
        if mode.wantsStreaming || (mode.wantsRecording && directRecordingEnabled) {
            startupStage = "pipeline.prepare"
            do {
                try await prepareMediaPipeline(source: source, filter: filter)
                if mode.wantsStreaming { try await preparePublishing(size: size) }
            }
            catch is CancellationError { throw CancellationError() }
            catch {
                logFailure(error, stage: startupStage)
                streamingViable = false
                await stopPublishing()
                guard hasRecording else { throw error }
                update(.starting, "推流管線無法建立；將繼續本地錄製。")
            }
        }
        try Task.checkCancellation()
        startupStage = "capture.start"
        try await source.startCapture()
        startupStage = "capture.running"
        try Task.checkCancellation()
        guard state.transition(.streaming, for: token) else { throw CancellationError() }
        update(.streaming, nil)
        if streamingViable {
            publishingTask = Task { [self] in
                do { try await startPublishing() }
                catch is CancellationError { }
                catch {
                    logFailure(error, stage: publishingStage)
                    let stage = publishingStage
                    publishingStage = "failed"
                    let code = (error as NSError).code
                    // 清理工作另開 Task，避免等待自己。
                    Task { await self.publishingFailed("推流啟動失敗（\(stage)，錯誤碼 \(code)），詳細原因請查看日誌。") }
                }
            }
        }
        // 診斷回報起點：擷取啟動成功後立即取樣，每輪完成再等待 5 秒。
        // 此工作由擷取生命週期持有，finish() 會取消並等待結束；
        // RTMP 失敗但本地可控錄製繼續時，仍能回報 Mixer 資料。
        diagnostics = Task { [weak self] in
            var sampleCount = 0
            while !Task.isCancelled {
                guard let self else { return }
                let queues = self.pump.map { "video{\($0.video.summary)} audio{\($0.audio.summary)} mic{\($0.mic.summary)}" } ?? "sampleQueues=none"
                sendlog(message: "[CaptureSource] backend=screenCaptureKit session=\(token) mode=\(self.mode.rawValue) capturePhase=\(self.state.phase.rawValue) publishPhase=\(self.publishingStage) \(queues)")
                if let sink = self.recordingSink { sendlog(message: "[SegmentedRecordingQueue] \(sink.summary)") }
                self.telemetry.sourceQueues = queues
                self.telemetry.pipelineSampledAt = Date()
                sampleCount += 1
                if sampleCount % 6 == 1 { self.logResources(stage: "sampling") }
                if let mixer = self.pipeline?.mixer {
                    let health = await mixer.audioPipelineDiagnostics()
                    guard !Task.isCancelled else { return }
                    let tracks = health.tracks.map { "track=\($0.trackId) converted=\($0.outputFrames) noData=\($0.resampleNoDataCount) buffered=\($0.ringBufferCounts) overflow=\($0.overflowDroppedSamples) gap=\($0.skipInsertedSamples)" }.joined(separator: " | ")
                    self.telemetry.mixerAudio = "mixed=\(health.mixerOutputFrames) ready=\(health.mixerReady) channels=\(health.outputChannels) \(self.audioProbe?.summary() ?? "probe=none")"
                    sendlog(message: "[CaptureAudioPipeline] session=\(token) mixed=\(health.mixerOutputFrames) ready=\(health.mixerReady) error=\(health.lastError ?? "none") channels=\(health.outputChannels) rms=\(health.outputChannelRMS) \(self.audioProbe?.summary() ?? "probe=none") \(tracks)")
                }
                if let probe = self.streamDiagnosticsProbe {
                    let snapshot: StreamDiagnosticsSnapshot
                    if let stream = self.output, let connection = self.connection {
                        // 組合 Mixer 實測、實際壓縮格式與 RTMP 傳輸快照。
                        snapshot = await probe.snapshot(source: "ScreenCaptureKit", stream: stream, connection: connection)
                    } else {
                        // 純本地可控錄製只有 Mixer，不能補出不存在的 RTMP 指標。
                        snapshot = probe.mixerSnapshot(source: "ScreenCaptureKit", phase: self.state.phase.rawValue)
                    }
                    guard !Task.isCancelled else { return }
                    // 實際回報設備頁的入口：同程序直接更新共用 Model。
                    // ReplayKit 則經 Socket 解碼後呼叫同一個 record()。
                    StreamDiagnosticsModel.shared.record(snapshot)
                }
                guard !Task.isCancelled else { return }
                // 另一條摘要回報：更新 CaptureCoordinator 的擷取／連線狀態，
                // 與上方供格式明細、影音速率圖表使用的 Model 分開。
                self.telemetryChanged(self.telemetry)
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
    }
    /// Mixer 由擷取生命週期持有，RTMP 斷線不影響本地可控錄製。
    /// 建立取樣佇列、診斷探針與可選錄製輸出，並啟動即時音量同步工作。
    /// - Parameters:
    ///   - source: 要掛載影音取樣接收器的 SCStream。
    ///   - filter: 用於判斷是否掛載麥克風輸入。
    /// - Throws: 取樣處理器建立或系統輸出掛載失敗。
    private func prepareMediaPipeline(source: SCStream, filter: SCContentFilter) async throws {
        let defaults = userDefaults ?? .standard
        let pipeline = CaptureMediaPipeline()
        self.pipeline = pipeline
        // 掛載僅讓 Probe 接收 Mixer 回呼並累計資料，不會自行更新 UI。
        // 設備頁回報由上方 diagnostics Task 定期組合快照，再呼叫 record()。
        let diagnosticsProbe = StreamDiagnosticsProbe()
        streamDiagnosticsProbe = diagnosticsProbe
        await pipeline.mixer.addOutput(diagnosticsProbe)
        var mixing = CaptureMediaPipeline.audioSettings(from: await pipeline.mixer.audioMixerSettings, microphone: filter.isMicrophoneEnabled)
        mixing.tracks[0]?.volume = Self.volume(defaults, key: "appVolume")
        mixing.tracks[1]?.volume = Self.volume(defaults, key: "micVolume")
        await pipeline.mixer.setAudioMixerSettings(mixing)
        var videoMixing = await pipeline.mixer.videoMixerSettings
        videoMixing.mode = .passthrough
        await pipeline.mixer.setVideoMixerSettings(videoMixing)
        let probe = ScreenAudioProbe(session: state.id?.uuidString ?? "none")
        audioProbe = probe
        await pipeline.mixer.addOutput(probe)
        if mode.wantsRecording && directRecordingEnabled {
            let sink = SegmentedRecordingSink(settings: DirectRecordingSettings(defaults: defaults), library: RecordingLibrary.shared) { [weak self] message in
                guard let self else { return }
                self.directRecordingFailed = true
                self.update(self.state.phase, message)
                if !self.streamingViable { Task { await self.finish(message: message) } }
            }
            recordingSink = sink
            await pipeline.mixer.addOutput(sink)
        }
        await pipeline.mixer.startRunning()
        let policy = StreamFramePolicy.current
        let recordingSettings = DirectRecordingSettings(defaults: defaults)
        let usesRecordingCanvas = mode.wantsRecording && directRecordingEnabled
        let canvas = usesRecordingCanvas ? recordingSettings.canvas : policy.fixedCanvas
        let fills = usesRecordingCanvas ? recordingSettings.fillsCanvas : policy.fillsCanvas
        sendlog(message: "[CaptureCanvas] recording=\(usesRecordingCanvas) canvas=\(String(describing: canvas)) fills=\(fills) overlayCoordinates=canvas")
        let pump = try ScreenSamplePump(mixer: pipeline.mixer, probe: probe,
            rotateLeft: defaults.object(forKey: "screenStreamRotateLeft") as? Bool ?? true,
            canvas: canvas, fills: fills)
        self.pump = pump
        try source.addStreamOutput(pump, type: .screen, sampleHandlerQueue: sampleQueue)
        try source.addStreamOutput(pump, type: .audio, sampleHandlerQueue: sampleQueue)
        if filter.isMicrophoneEnabled { try source.addStreamOutput(pump, type: .microphone, sampleHandlerQueue: sampleQueue) }
        mediaPrepared = true
        // 同程序設定以低頻率合併讀取，不依賴僅傳給擴展的 Darwin 通知。
        volumeUpdates = Task { [weak self] in
            var previous: [Float] = []
            while !Task.isCancelled {
                guard let self, let mixer = self.pipeline?.mixer else { return }
                let values = [Self.volume(defaults, key: "appVolume"), Self.volume(defaults, key: "micVolume")]
                if values != previous {
                    var settings = await mixer.audioMixerSettings
                    guard !Task.isCancelled else { return }
                    settings.tracks[0]?.volume = values[0]
                    settings.tracks[1]?.volume = values[1]
                    await mixer.setAudioMixerSettings(settings)
                    previous = values
                    sendlog(message: "[CaptureAudioSettings] appVolume=\(values[0]) micVolume=\(values[1]) live=true")
                }
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            }
        }
    }
    /// 防止非有限值或異常增益傳入 Mixer；0 靜音、1 原音量、最多 4 倍。
    private static func volume(_ defaults: UserDefaults, key: String) -> Float {
        let value = defaults.object(forKey: key) as? Double ?? 1
        return value.isFinite ? Float(min(4, max(0, value))) : 1
    }
    /// 建立 RTMP 連線物件、編碼設定與日誌回呼，將串流掛到既有 Mixer。
    /// 此步驟尚未連線；實際 connect／publish 由 startPublishing() 執行。
    /// - Parameter size: 未指定固定畫布時採用的尺寸。
    /// - Throws: Mixer 不存在或編碼設定套用失敗；已建立資源由外層清理。
    private func preparePublishing(size: CGSize) async throws {
        let defaults = userDefaults ?? .standard
        guard let pipeline else { throw CancellationError() }
        let conn = RTMPConnection(minimumLogLevel: .debug)
        let stream = RTMPStream(connection: conn)
        connection = conn; output = stream
        let logSession = state.id?.uuidString ?? "none"
        let logSecrets = [url, key]
        await conn.setOnLog { [weak self] event in
            // 放行連線生命週期、低頻佇列／時間軸摘要及同步事件；仍遮蔽敏感資訊。
            let prefixes = ["VideoQueue", "TCP ", "State:", "S0 version", "S0S1 received",
                            "Waiting for S2", "Response:", "Connect ", "Command error",
                            "Command timeout", "Socket recv", "Close requested", "Reconnect",
                            "Reconnecting", "Keepalive", "Liveness watchdog", "Output continuity",
                            "audio:", "audio track", "inputFormat:", "AudioCodec", "publish throughput", "publish timeline", "audio resync:", "A/V",
                            "audio stall", "Restarting audio", "failedTo", "unableTo"]
            guard event.level == .error || prefixes.contains(where: { event.message.hasPrefix($0) }) else { return }
            let detail = CaptureErrorDiagnostics.sanitize(event.message + " " + (event.detail ?? ""), secrets: logSecrets)
            sendlog(message: "[CaptureTransport] session=\(logSession) \(detail)")
            Task { @MainActor [weak self] in
                guard let self, self.state.id?.uuidString == logSession,
                      self.state.phase != .stopping, self.state.phase != .idle else { return }
                self.telemetry.consume(message: event.message, detail: event.detail, now: event.timestamp)
                // 重連成功只代表恢復發布流程；收到本次的新輸出才恢復直播狀態。
                if self.publishingStage == "rtmp.publish",
                   event.message == "publish throughput",
                   event.timestamp >= self.telemetry.stageStartedAt,
                   self.telemetry.stage == "published" {
                    self.publishingStage = "published"
                    self.publishingChanged(true)
                    self.logStage()
                }
                self.telemetryChanged(self.telemetry)
            }
        }
        try Task.checkCancellation()
        var video = await stream.videoSettings
        // 編碼畫布沿用與 ReplayKit 相同的慣例：RTMP 直接用 (odstW, odstH)，不在此轉置
        //（ReplayKit SampleHandler 的 encoderW/H = ODWidth/ODHeight）。SC 擷取緩衝的寬高
        // 本身與設定是轉置的，旋轉後剛好對上這個畫布；先前在此再交換會讓輸出變成 1080×1920（直的）。
        // 輸出畫布政策：預設 16:9（含黑邊）；native 沿用來源尺寸。
        let framePolicy = StreamFramePolicy.current
        let recordingSettings = DirectRecordingSettings(defaults: defaults)
        video.videoSize = mode.wantsRecording && directRecordingEnabled
            ? (recordingSettings.canvas ?? size) : (framePolicy.fixedCanvas ?? size)
        video.bitRate = max(100_000, defaults.object(forKey: "bitRate") as? Int ?? 6_000_000)
        video.maxKeyFrameIntervalDuration = Int32(max(0, min(60, defaults.object(forKey: "KeyFrameInterval") as? Int ?? 2)))
        video.allowFrameReordering = false
        video.scalingMode = .letterbox
        video.expectedFrameRate = 60
        video.profileLevel = H264EncodingProfile.resolve(defaults.string(forKey: "h264level") ?? "AutoHigh")
        // 與 ReplayKit 相同：Baseline 必須使用 CAVLC。
        video.h264EntropyMode = video.profileLevel.contains("Baseline") ? "cavlc" : nil
        switch defaults.integer(forKey: "BitRateMode") {
        case 1: video.bitRateMode = .constant
        case 2: video.bitRateMode = .variable
        default: video.bitRateMode = .average
        }
        startupStage = "pipeline.videoSettings"
        try await stream.setVideoSettings(video)
        await stream.setBitRateStrategy(StreamVideoAdaptiveBitRateStrategy(mamimumVideoBitrate: video.bitRate))
        await conn.setReconnectEnabled(true)
        let reconnectSession = state.id
        await conn.setOnReconnectStateChanged { [weak self] reconnect in
            await self?.handleReconnect(reconnect, session: reconnectSession)
        }
        var audio = await stream.audioSettings
        let audioBitrate = StreamAudioBitrate.load(from: defaults)
        audio.bitRate = audioBitrate.resolve(recommended: AudioCodecSettings.recommendedRtmpBitrate)
        audio.format = AudioCodecSettings.recommendedRtmpFormat
        startupStage = "pipeline.audioSettings"
        try await stream.setAudioSettings(audio)
        telemetry.targetBitrate = audio.bitRate
        await pipeline.mixer.addOutput(stream)
    }
    /// 同步重連生命週期；忽略舊工作與停止期間的回呼，避免收尾後重新顯示直播中。
    /// - Parameters:
    ///   - reconnect: 底層重試進度；成功仍需等待新的輸出摘要。
    ///   - session: 安裝回呼時的擷取識別碼。
    private func handleReconnect(_ reconnect: RTMPConnection.ReconnectState, session: UUID?) async {
        guard session == state.id, session != nil,
              state.phase != .idle, state.phase != .stopping, !cleaningPublishing else { return }
        switch reconnect {
        case .started, .failed:
            publishingStage = "reconnect"
            publishingChanged(false)
        case .succeeded:
            publishingStage = "rtmp.publish"
        case .exhausted:
            await publishingFailed("網路重連次數已達上限，推流已停止。")
            return
        }
        telemetry.audioPackets = nil
        telemetry.sampledAt = nil
        logStage()
    }
    /// 依序連接 RTMP 服務器並發布串流，成功後才通知上層正在推流。
    /// - Throws: 連線／發布失敗、必要物件不存在或工作取消。
    private func startPublishing() async throws {
        guard let conn = connection, let stream = output else { throw CancellationError() }
        try Task.checkCancellation()
        publishingStage = "rtmp.connect"
        sendlog(message: "[CaptureEndpoint] session=\(state.id?.uuidString ?? "none") transport=HaishinKit \(CaptureErrorDiagnostics.endpoint(url, key: key))")
        logStage()
        _ = try await conn.connect(url)
        try Task.checkCancellation()
        publishingStage = "rtmp.publish"
        logStage()
        _ = try await stream.publish(key)
        try Task.checkCancellation()
        publishingStage = "published"
        logStage()
        publishingChanged(true)
    }
    /// 將發布階段映射到上層連線摘要並寫入日誌；已失敗時保留失敗摘要。
    private func logStage() {
        if !telemetry.failed {
            telemetry.stage = publishingStage == "reconnect" ? "reconnect" :
                (publishingStage == "published" ? "published" : (publishingStage == "rtmp.publish" ? "publish" : "tcp"))
            telemetry.stageStartedAt = Date()
            telemetryChanged(telemetry)
        }
        sendlog(message: "[CaptureSource] session=\(state.id?.uuidString ?? "none") mode=\(mode.rawValue) publishPhase=\(publishingStage)")
    }
    /// 遮蔽端點與金鑰後記錄錯誤；RTMP 階段的錯誤另更新推流失敗狀態。
    /// 本函式只回報，不負責停止或釋放資源。
    /// - Parameters:
    ///   - error: 原始錯誤，供診斷展開錯誤型別與原因。
    ///   - stage: 失敗所在階段；以 rtmp. 開頭時標記推流失敗。
    private func logFailure(_ error: Error, stage: String) {
        if stage.hasPrefix("rtmp.") {
            telemetry.failed = true
            telemetryChanged(telemetry)
        }
        let detail = CaptureErrorDiagnostics.describe(error, secrets: [url, key])
        sendlog(message: "[CaptureError] session=\(state.id?.uuidString ?? "none") mode=\(mode.rawValue) stage=\(stage) \(detail)")
    }
    /// 清理失敗的發布工作；有本地錄製時保留錄製，否則結束整次擷取。
    /// 會等待 publishingTask，須由該工作以外的 Task 呼叫，避免等待自己。
    /// - Parameter message: 顯示於上層的錯誤摘要。
    private func publishingFailed(_ message: String) async {
        guard state.id != nil, state.phase != .stopping, !cleaningPublishing else { return }
        telemetry.failed = true
        telemetryChanged(telemetry)
        publishingStage = "failed"
        logStage()
        cleaningPublishing = true
        streamingViable = false
        publishingTask?.cancel()
        await publishingTask?.value; publishingTask = nil
        await stopPublishing()
        if recordingSink == nil { await stopMediaPipeline() }
        cleaningPublishing = false
        guard state.phase != .stopping else { return }
        if hasRecording {
            update(state.phase, message + " 本地錄製繼續。")
        } else { await finish(message: message) }
    }
    /// 停用重連、關閉並卸載 RTMP 輸出；保留 Mixer、診斷探針與本地錄製。
    /// 呼叫端負責先停止發布工作；關閉錯誤不阻斷後續資源清理。
    private func stopPublishing() async {
        if !telemetry.failed, telemetry.stage != "idle" {
            telemetry.stage = "stopped"
            telemetryChanged(telemetry)
        }
        publishingChanged(false)
        if let connection { await connection.setReconnectEnabled(false) }
        if let output {
            logResources(stage: "rtmp.close.begin")
            _ = try? await output.close()
            logResources(stage: "rtmp.close.end")
            await pipeline?.mixer.removeOutput(output)
        }
        logResources(stage: "connection.close.begin")
        _ = try? await connection?.close()
        logResources(stage: "connection.close.end")
        output = nil; connection = nil
    }
    /// 停止音量同步、解除來源回呼並等待取樣工作結束，再卸載探針與收尾錄製。
    /// 釋放 Mixer 管線；SCStream 本身與 RTMP 連線由外層分別停止。
    private func stopMediaPipeline() async {
        volumeUpdates?.cancel()
        await volumeUpdates?.value; volumeUpdates = nil
        if let pump, let capture {
            try? capture.removeStreamOutput(pump, type: .screen)
            try? capture.removeStreamOutput(pump, type: .audio)
            try? capture.removeStreamOutput(pump, type: .microphone)
        }
        logResources(stage: "pump.finish.begin")
        await pump?.finish(); pump = nil
        logResources(stage: "pump.finish.end")
        if let audioProbe { await pipeline?.mixer.removeOutput(audioProbe) }
        audioProbe = nil
        if let streamDiagnosticsProbe { await pipeline?.mixer.removeOutput(streamDiagnosticsProbe) }
        streamDiagnosticsProbe = nil
        await pipeline?.mixer.stopRunning()
        if let recordingSink {
            await pipeline?.mixer.removeOutput(recordingSink)
            await recordingSink.finish()
        }
        recordingSink = nil
        mediaPrepared = false
        pipeline = nil
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let identity = ObjectIdentifier(stream)
        let code = (error as NSError).code
        Task { @MainActor [weak self] in
            guard let self, let current = self.capture, ObjectIdentifier(current) == identity,
                  self.state.phase != .stopping else { return }
            self.logFailure(error, stage: "capture.delegateStop")
            await self.finish(message: "系統已停止畫面分享（錯誤碼 \(code)）。")
        }
    }
    /// 不能將仍啟用的共用 session 還原為排他 category，否則會中斷其他 App 播放。
    /// 不停用共用 session：PiP／TTS 可能仍在使用；保持可混音，交回既有擁有者管理。
    private func restoreMixingAudioSession() {
        guard ownsAudioSession else { return }
        defer { ownsAudioSession = false }
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playAndRecord, session.categoryOptions.contains(.mixWithOthers) else {
            logAudioSession("restore.skippedSessionChanged")
            return
        }
        // 實機紀錄顯示：即使兩邊都允許混音，切換 category 仍可能令外部影片暫停。
        // 有其他音訊時不切換、不 deactivate／reactivate；擷取已停止，後續由 PiP/TTS
        // 真正需要音訊時再設定 session。此處也不排程延遲還原，避免稍後再打斷播放。
        if session.isOtherAudioPlaying {
            logAudioSession("restore.deferredOtherAudioPlaying")
            return
        }
        let compatible = priorCategory == .playback || priorCategory == .playAndRecord || priorCategory == .multiRoute
        let category: AVAudioSession.Category = compatible ? (priorCategory ?? .playback) : .playback
        let mode: AVAudioSession.Mode = compatible ? (priorMode ?? .default) : .default
        var options: AVAudioSession.CategoryOptions = compatible ? priorOptions : []
        options.remove(.duckOthers)
        options.remove(.interruptSpokenAudioAndMixWithOthers)
        options.insert(.mixWithOthers)
        do {
            logAudioSession("restore.begin")
            if session.category != category || session.mode != mode || session.categoryOptions != options {
                try session.setCategory(category, mode: mode, options: options)
            }
            logAudioSession("restore.mixingComplete")
        } catch {
            // 失敗時維持現有混音設定，不再嘗試排他還原或重新啟用。
            logFailure(error, stage: "audioSession.restoreMixing")
        }
    }
    /// 記錄主 App 音訊 session 的類別、混音選項及路由，供追查外部播放中斷。
    /// - Parameter event: 呼叫端提供的生命週期事件名稱。
    private func logAudioSession(_ event: String) {
        let audio = AVAudioSession.sharedInstance()
        let outputs = audio.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        sendlog(message: "[CaptureAudio] session=\(state.id?.uuidString ?? "none") event=\(event) category=\(audio.category.rawValue) mode=\(audio.mode.rawValue) options=\(audio.categoryOptions.rawValue) otherAudio=\(audio.isOtherAudioPlaying) outputs=\(outputs)")
    }
    /// 訂閱音訊中斷與路由變更，僅記錄事件，不自行重啟擷取或修改音訊設定。
    /// 觀察者由 finish(message:) 統一移除；每次啟動只呼叫一次。
    /// - Parameter token: 寫入事件日誌的本次擷取識別碼。
    private func observeAudioSession(token: UUID) {
        let center = NotificationCenter.default
        let interruption = center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue
            sendlog(message: "[CaptureAudio] session=\(token) event=interruption type=\(type.map(String.init) ?? "unknown") options=\(options.map(String.init) ?? "unknown")")
        }
        let route = center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            sendlog(message: "[CaptureAudio] session=\(token) event=routeChange reason=\(reason.map(String.init) ?? "unknown")")
        }
        audioObservers = [interruption, route]
    }
    /// 每三十秒及收尾 await 邊界記錄本程序用量；不代表廣播擴展用量。
    private func logResources(stage: String) {
        let memory = DeviceInfo.memoryBreakdown
        let values = String(format: "footprintMB=%.1f compressedMB=%.1f residentMB=%.1f availableMB=%.1f",
                            memory.footprintMB, memory.compressedMB, memory.residentMB, memory.availableMB)
        sendlog(message: "[CaptureResources] session=\(state.id?.uuidString ?? "none") stage=\(stage) \(values)")
    }
    func stop() async { await finish(message: nil) }
    /// 結束整次擷取：取消並等待背景工作，收尾錄製、RTMP、Mixer 與系統觀察者。
    /// 收尾期間重複呼叫直接返回；完成後釋放音訊所有權並通知上層回到 idle。
    /// 不可由 operation／diagnostics／publishingTask 本身直接等待此函式，以免自我等待。
    /// - Parameter message: 收尾完成後顯示的訊息；正常停止可傳 nil。
    private func finish(message: String?) async {
        guard let token = state.id, state.phase != .stopping else { return }
        sendlog(message: "[CaptureSource] session=\(token) stopping publishPhase=\(publishingStage)")
        state.stopping(); update(.stopping, nil)
        operation?.cancel(); diagnostics?.cancel()
        // 等待跨 actor 的診斷查詢返回，避免停止後仍發布晚到快照。
        await diagnostics?.value; diagnostics = nil
        // 等待啟動中的 await 結束，避免停止後又建立擷取或 RTMP 連線。
        await operation?.value; operation = nil
        publishingTask?.cancel()
        await publishingTask?.value; publishingTask = nil
        // 若輸出失敗清理已在進行，讓其結束，避免對 RTMP/Mixer 重複 close。
        while cleaningPublishing { try? await Task.sleep(nanoseconds: 10_000_000) }
        if let capture {
            recording?.detach(from: capture)
            logAudioSession("capture.stopBegin")
            do { try await capture.stopCapture() }
            catch { logFailure(error, stage: "capture.stop") }
            logAudioSession("capture.stopEnd")
        }
        if let recordingOrientation, let capture {
            try? capture.removeStreamOutput(recordingOrientation, type: .screen)
        }
        await recording?.awaitCompletion(); recording = nil; recordingOrientation = nil
        await stopPublishing()
        await stopMediaPipeline(); capture = nil
        let picker = SCContentSharingPicker.shared
        picker.remove(self); picker.isActive = false
        restoreMixingAudioSession()
        logAudioSession("capture.cleanupComplete")
        for observer in audioObservers { NotificationCenter.default.removeObserver(observer) }
        audioObservers.removeAll()
        CaptureAudioOwnership.shared.end()
        state.finish(token); update(.idle, message)
    }
}
#endif
