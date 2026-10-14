#if os(iOS)
import Foundation
@preconcurrency import AVFoundation
import HaishinKit

private struct RecordingSample: @unchecked Sendable { let buffer: CMSampleBuffer }

/// Mixer 回呼只複製／入列；單一消費工作持有 Writer，佇列最多 48 MiB。
/// 過載丟樣本並記錄計數，不能以無限佇列換取表面上的無丟幀。
final class SegmentedRecordingSink: MediaMixerOutput, @unchecked Sendable {

    let videoTrackId: UInt8? = UInt8.max
    let audioTrackId: UInt8? = UInt8.max
    private let mailbox: CaptureMailbox<RecordingSample>
    private let worker: Task<Void, Never>

    /// 初始化分片錄製工具
    /// - Parameters:
    ///   - settings: 開錄時固定的編碼與分段設定。
    ///   - library: 管理片段清單與檔案路徑的錄製庫。
    ///   - failed: 寫入或收尾失敗時在 MainActor 執行的通知，參數為顯示訊息。
    init(settings: DirectRecordingSettings, library: RecordingLibrary, failed: @escaping @MainActor @Sendable (String) -> Void) {
        let mailbox = CaptureMailbox<RecordingSample>(budget: 48 * 1024 * 1024, age: 2)
        self.mailbox = mailbox
        worker = Task {
            let writer = SegmentedRecordingWriter(settings: settings, library: library)
            do {
                for await sample in mailbox.stream() { try await writer.append(sample.buffer) }
                try await writer.finishSegment()
            } catch {
                mailbox.finish()
                await writer.failed(error)
                await failed("分段錄製已停止：" + error.localizedDescription)
            }
            sendlog(message: "[SegmentedRecording] " + mailbox.summary)
        }
    }
    /// 供低頻率診斷取樣，不產生逐幀日誌。
    var summary: String { mailbox.summary }

    /// 滿足輸出協定；固定接收 Mixer 混合軌道，不執行軌道切換。
    /// - Parameters:
    ///   - id: 要求的軌道 ID；此實作忽略。
    ///   - mediaType: 要求的媒體種類；此實作忽略。
    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async {}

    /// 將含影像的視訊樣本入列；缺少影像時略過。
    /// - Parameters:
    ///   - mixer: 提供合成畫面的 Mixer。
    ///   - sampleBuffer: 保留原時間戳的樣本，以像素緩衝區大小估計佇列用量。
    func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        guard let image = sampleBuffer.imageBuffer else { return }
        mailbox.offer(RecordingSample(buffer: sampleBuffer), bytes: CVPixelBufferGetDataSize(image))
    }

    /// 將 PCM 音訊複製成獨立樣本後入列；時間無效、空音訊或轉換失敗時略過。
    /// - Parameters:
    ///   - mixer: 提供混音結果的 Mixer。
    ///   - buffer: 本次回呼提供的 PCM 音訊。
    ///   - when: 必須含有效 hostTime，用來建立媒體時間戳。
    func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard when.isHostTimeValid, buffer.frameLength > 0 else { return }
        let pts = CMTime(seconds: AVAudioTime.seconds(forHostTime: when.hostTime), preferredTimescale: 1_000_000_000)
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: buffer.format.formatDescription, sampleCount: Int(buffer.frameLength),
            presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sample) == noErr,
            let sample,
            CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: buffer.audioBufferList) == noErr else { return }
        mailbox.offer(RecordingSample(buffer: sample), bytes: CMSampleBufferGetTotalSampleSize(sample))
    }

    /// 先停止接收，再消費已入列的尾端樣本；不取消 writer 收尾。
    func finish() async {
        mailbox.finish(discardPending: false)
        await worker.value
    }
}

/// 每段是一個獨立 AVAssetWriter，確認完成後才把 manifest 標成可播放。
private actor SegmentedRecordingWriter {

    /// 錄製設定，包含切段秒數與編碼選項。
    private let settings: DirectRecordingSettings
    /// 錄製檔案庫，負責 manifest 與檔案路徑。
    private let library: RecordingLibrary
    /// UUID，所有切段屬於同一組。
    private let group = UUID()
    /// 片段流水號；尚未建立時為 0，第一段建立時遞增為 1。
    private var number = 0
    /// 當前切段的寫入器。
    private var writer: AVAssetWriter?
    /// 當前切段的視訊軌道。
    private var video: AVAssetWriterInput?
    /// 當前切段的音訊軌道。
    private var audio: AVAssetWriterInput?
    /// 當前切段的錄製檔案 ID。
    private var id: UUID?
    /// 當前切段的檔案路徑。
    private var url: URL?
    /// 本段首個視訊樣本的 PTS，屬於媒體時間軸，不是日期時間。
    private var start: CMTime = .invalid
    /// 本段最後成功寫入的視訊 PTS；尚未寫入時為 invalid。
    private var lastVideo: CMTime = .invalid
    /// 本段最後成功寫入的音訊 PTS；尚未寫入時為 invalid。
    private var lastAudio: CMTime = .invalid
    /// 最後一次報告的時間戳（秒）。
    private var lastReport = -Double.infinity
    /// 本段最近成功讀取的檔案大小；讀取失敗時保留，不以零覆寫。
    private var lastKnownBytes: Int64 = 0
    /// 本段最近的容量讀取錯誤，用來抑制連續重複日誌；成功讀取後清除。
    private var sizeReadError: String?

    /// 整次錄製累計的寫入端丟棄數，切段不歸零。
    /// 包含時間戳無效／倒退與輸入未就緒；不含 FPS 篩選、佇列丟棄或音訊轉換失敗。
    private var dropped = 0
    /// 本段成功寫入的視訊樣本數；每段歸零，用來拒絕空片段。
    private var videoCount = 0
    /// 限制影格率的工具。
    private var limiter: RecordingFrameRateLimiter

    /// 建立片段狀態，收到首個視訊樣本才開檔；由單一消費工作依序呼叫。
    /// - Parameters:
    ///   - settings: 本次錄製的固定設定快照。
    ///   - library: 在 MainActor 管理錄製紀錄的檔案庫。
    init(settings: DirectRecordingSettings, library: RecordingLibrary) {
        self.library = library
        self.settings = settings
        limiter = RecordingFrameRateLimiter(limit: settings.encoding.fpsLimit)
    }

    /// 建立本模組的錯誤；此處不寫入日誌。
    /// - Parameter message: 顯示給使用者的錯誤描述。
    /// - Returns: domain 為 SegmentedRecording、code 為 1 的 NSError。
    private func error(_ message: String) -> NSError {
        NSError(domain: "SegmentedRecording", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// 依時間戳寫入樣本；遇分段邊界先收尾，再用該視訊樣本開新段。
    /// 首個視訊前的音訊會略過；一般輸入未就緒時丟棄，不無限等待。
    /// - Parameter sample: Mixer 輸出的視訊或 PCM 樣本。
    /// - Throws: 開檔、寫入、收尾或首幀等待失敗；等待被取消亦會拋錯。
    func append(_ sample: CMSampleBuffer) async throws {
        let isVideo = sample.imageBuffer != nil
        let pts = sample.presentationTimeStamp
        guard pts.seconds.isFinite else { dropped += 1; return }
        if isVideo, writer != nil, pts.seconds - start.seconds >= settings.segmentSeconds {
            try await finishSegment()
        }
        if writer == nil {
            guard isVideo else { return }
            try await begin(sample)
        }
        guard let writer, pts >= start else { dropped += 1; return }
        guard writer.status == .writing else { throw writer.error ?? error("編碼器已停止寫入。") }
        let previous = isVideo ? lastVideo : lastAudio
        guard !previous.isValid || pts > previous else { dropped += 1; return }
        if isVideo && !limiter.accepts(seconds: pts.seconds) { return }
        guard let input = isVideo ? video : audio else { throw error("缺少編碼輸入軌道。") }
        if isVideo && videoCount == 0 {
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while !input.isReadyForMoreMediaData && writer.status == .writing && ContinuousClock.now < deadline {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard input.isReadyForMoreMediaData else { throw writer.error ?? error("片段首幀等待編碼器逾時。") }
        }
        guard input.isReadyForMoreMediaData else { dropped += 1; return }
        guard input.append(sample) else { throw writer.error ?? error("媒體樣本寫入失敗。") }
        if isVideo { lastVideo = pts; videoCount += 1 } else { lastAudio = pts }
        if pts.seconds - lastReport >= 1 {
            lastReport = pts.seconds
            await report(phase: nil)
        }
    }

    /// 以首個視訊樣本建立 MP4；音訊輸出固定為 AAC、48 kHz、雙聲道、128 kbps。
    /// 自動碼率會省略平均碼率設定，但仍重新編碼。10 秒 fragment 不等於獨立片段。
    /// - Parameter sample: 決定起始 PTS 與來源尺寸的視訊樣本。
    /// - Throws: 檔案庫、設定相容性、輸入軌道或開始寫入錯誤。
    private func begin(_ sample: CMSampleBuffer) async throws {
        guard let image = sample.imageBuffer else { throw error("缺少視訊畫面。") }
        let item = try await library.create()
        id = item.id
        let file = await library.fileURL(for: item.id)
        url = file
        number += 1
        lastKnownBytes = 0
        sizeReadError = nil

        await library.identifySegment(item.id, group: group, number: number)
        let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
        
        self.writer = writer
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        
        let size = settings.encoding.outputSize(CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image)))
        var compression: [String: Any] = [AVVideoMaxKeyFrameIntervalDurationKey: 2, AVVideoAllowFrameReorderingKey: false]
        
        if !settings.automaticBitrate { compression[AVVideoAverageBitRateKey] = settings.encoding.megabits * 1_000_000 }
        
        let videoSettings: [String: Any] = [AVVideoCodecKey: settings.encoding.hevc ? AVVideoCodecType.hevc : .h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: compression]
        
        let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000]
        
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video),
              writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else { throw error("裝置不支援所選錄製設定。") }
        
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings, sourceFormatHint: sample.formatDescription)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        
        video.expectsMediaDataInRealTime = true; audio.expectsMediaDataInRealTime = true
        
        guard writer.canAdd(video), writer.canAdd(audio) else { throw error("無法建立錄製軌道。") }
        writer.add(video); writer.add(audio)
        
        self.video = video; self.audio = audio
        
        guard writer.startWriting() else { throw writer.error ?? error("無法開始錄製。") }
        
        start = sample.presentationTimeStamp
        writer.startSession(atSourceTime: start)
        lastVideo = .invalid; lastAudio = .invalid; videoCount = 0
        limiter = RecordingFrameRateLimiter(limit: settings.encoding.fpsLimit)
        lastReport = -Double.infinity
        await report(phase: .recording)
    }

    /// 完成片段並驗證可播放性；沒有寫入器時直接返回。
    /// 收尾等待 30 秒後要求取消寫入；驗證成功才標記 ready 並清除目前片段狀態。
    /// - Throws: 寫入未完成、沒有視訊、資產讀取或可播放性驗證失敗。
    func finishSegment() async throws {
        guard let writer else { return }
        await report(phase: .finishing)
        video?.markAsFinished(); audio?.markAsFinished()
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: 30_000_000_000); writer.cancelWriting() } catch { }
        }
        await writer.finishWriting()
        timeout.cancel()
        
        guard writer.status == .completed, videoCount > 0 else { throw writer.error ?? error("片段未完整收尾，原檔保留供恢復。") }
        
        guard let segmentURL = self.url else { throw error("缺少片段路徑。") }
        
        let asset = AVURLAsset(url: segmentURL)
        
        let duration = try await asset.load(.duration)
        
        guard try await asset.load(.isPlayable), duration.seconds.isFinite, duration.seconds > 0,
              !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
            throw error("片段可播放性驗證失敗，檔案保留。")
        }
        
        await report(phase: .ready, completedDuration: duration.seconds)
        
        sendlog(message: "[SegmentedRecording] group=\(group) segment=\(number) completed dropped=\(dropped)")
        // 清除實例持有的片段狀態；驗證用的 segmentURL 僅是區域快照。
        self.writer = nil
        self.video = nil
        self.audio = nil
        self.id = nil
        self.url = nil
    }
    /// 更新檔案大小、時長與整次錄製的寫入端丟棄數。
    /// - Parameters:
    ///   - phase: 要套用的階段；nil 保留原階段。
    ///   - completedDuration: 完成後讀取的資產秒數；nil 以最後視訊 PTS 減起點估算。
    private func report(phase: RecordingPhase?, completedDuration: Double? = nil) async {
        guard let id, let url else { return }
        // 錄製中的檔案會持續增長，直接查詢檔案系統，避免沿用 URL 的資源屬性快取。
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value >= 0 else {
                throw error("檔案屬性缺少有效大小。")
            }
            lastKnownBytes = size.int64Value
            if sizeReadError != nil {
                sendlog(message: "[SegmentedRecording] group=\(group) segment=\(number) id=\(id) event=fileSizeReadRecovered bytes=\(lastKnownBytes)")
            }
            sizeReadError = nil
        } catch {
            let failure = error as NSError
            let detail = "domain=\(failure.domain) code=\(failure.code) description=\(failure.localizedDescription) userInfo=\(failure.userInfo)"
            if sizeReadError != detail {
                sendlog(message: "[SegmentedRecording] group=\(group) segment=\(number) id=\(id) phase=\(phase?.rawValue ?? "progress") event=fileSizeReadFailed file=\(url.lastPathComponent) \(detail)")
            }
            sizeReadError = detail
        }
        let bytes = lastKnownBytes
        let sizeWarning = sizeReadError == nil ? "" : " · 大小讀取失敗（目前大小未確認）"
        let duration = completedDuration ?? (lastVideo.isValid ? max(0, lastVideo.seconds - start.seconds) : 0)
        let bitrate = settings.automaticBitrate ? "編碼器自動碼率" : "目標 \(settings.encoding.megabits) Mbps"
        await library.update(id, phase: phase, duration: duration, bytes: bytes,
            message: "可控錄製 · 第 \(number) 段 · \(bitrate) · 寫入端丟棄 \(dropped) 個樣本" + sizeWarning)
    }
    /// 取消目前寫入並標記中斷，不改動先前已完成的片段。
    /// 取消寫入不保證保留未完成檔案；恢復前仍須確認檔案存在且可播放。
    /// - Parameter failure: 寫入或收尾失敗的原始錯誤，供日誌診斷。
    func failed(_ failure: Error) async {
        writer?.cancelWriting()
        await report(phase: .interrupted)
        sendlog(message: "[SegmentedRecording] group=\(group) failed=\(failure)")
    }
}
#endif
