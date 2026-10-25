import Foundation
import AVFoundation
import HaishinKit
import RTMPHaishinKit

/// 兩種擷取來源共用的低頻快照；不攜帶媒體 buffer、伺服器網址或串流金鑰。
struct StreamDiagnosticsSnapshot: Codable, Sendable {
    var type = "streamDiagnostics"
    var schemaVersion = 1
    let source: String
    let session: UUID
    var sampledAt = Date()
    var phase: String
    var mixerVideo: String?
    var mixerAudio: String?
    /// 混音輸出 PCM 實測取樣率（Hz），不是來源或編碼設定；未收到 buffer 為 nil。
    var mixerAudioSampleRate: Double?
    /// Mixer 已交付的影片影格累計；舊版未提供時為 nil。
    var mixerVideoFrames: UInt64?
    /// Mixer 已交付的 PCM buffer 累計，不是 AAC 封包數。
    var mixerAudioBuffers: UInt64?
    /// Mixer 已交付的 PCM sample frames 累計，不乘聲道數。
    var mixerAudioFrames: UInt64?
    /// 計數取樣的單調時鐘秒數；只能在同一 session 內計算差分。
    var sampledUptime: Double?
    /// RTMPStream 觀測到的實際壓縮輸出；無 RTMP 管線或舊版未提供時為 nil。
    var encoding: RTMPEncodingDiagnostics?
    /// VT 成功回呼的同幀時間；舊來源或無編碼器時為 nil。
    var firstEncoderTiming: VideoEncoderTimingSample?
    var lastEncoderTiming: VideoEncoderTimingSample?
    /// ScreenCaptureKit 畫面加工摘要；未走本機加工時為 nil。
    var videoProcessing: String?
    /// 最近完整取樣區間的加工忙碌比例；首次或未提供時為 nil。
    var videoProcessingLoad: VideoProcessingLoadSnapshot?
    /// metalInFlight 表示 Metal 在途聯集比例；nil 沿用 ScreenCaptureKit worker 定義。
    var videoProcessingLoadKind: String?
    var videoSettings: String?
    var audioSettings: String?
    var encodedVideoFrames: UInt64?
    var videoMessagesQueued: UInt64?
    var generation: UInt64?
    var queuedBytes: Int?
    var completedBytes: Int?
    var failedBatchBytes: Int?
    var completedBatches: Int?
    var failedBatches: Int?
    var lastCompletionMilliseconds: Double?
}

/// 保存累計計數與最新格式；每秒最多解析一次附件，不保留媒體 buffer。
final class StreamDiagnosticsProbe: MediaMixerOutput, @unchecked Sendable {
    let videoTrackId: UInt8? = UInt8.max
    let audioTrackId: UInt8? = UInt8.max
    let session = UUID()
    private let lock = NSLock()
    private var video: String?
    private var audio: String?
    private var audioSampleRate: Double?
    private var firstVideoPTS: Double?
    private var firstAudioHostTime: Double?
    private var videoFrames: UInt64 = 0
    private var audioBuffers: UInt64 = 0
    private var audioFrames: UInt64 = 0
    private var lastVideoTime = -Double.infinity
    private var lastAudioTime = -Double.infinity

    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async {}

    func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        if firstVideoPTS == nil, sampleBuffer.presentationTimeStamp.seconds.isFinite {
            firstVideoPTS = sampleBuffer.presentationTimeStamp.seconds
            sendlog(message: "[MixerOrigin] session=\(session) track=video pts=\(firstVideoPTS!) clock=sourcePTS")
        }
        videoFrames &+= 1
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastVideoTime >= 1, let image = sampleBuffer.imageBuffer else { return }
        lastVideoTime = now
        let pixel = CVPixelBufferGetPixelFormatType(image)
        func attachment(_ key: CFString) -> String {
            guard let value = CVBufferCopyAttachment(image, key, nil) else { return "未提供" }
            return String(describing: value)
        }
        let range: String
        switch pixel {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: range = "Full"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: range = "Video"
        case kCVPixelFormatType_32BGRA: range = "RGB（此像素格式不區分 YUV Full/Video）"
        default: range = "未判定"
        }
        let matrix = pixel == kCVPixelFormatType_32BGRA ? "不適用（RGB）" : attachment(kCVImageBufferYCbCrMatrixKey)
        video = "\(CVPixelBufferGetWidth(image))×\(CVPixelBufferGetHeight(image)) · pixel=\(Self.fourCC(pixel)) · range=\(range) · primaries=\(attachment(kCVImageBufferColorPrimariesKey)) · transfer=\(attachment(kCVImageBufferTransferFunctionKey)) · matrix=\(matrix)"
    }

    func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        lock.lock(); defer { lock.unlock() }
        if firstAudioHostTime == nil, when.isHostTimeValid {
            firstAudioHostTime = AVAudioTime.seconds(forHostTime: when.hostTime)
            sendlog(message: "[MixerOrigin] session=\(session) track=audio pts=\(firstAudioHostTime!) clock=hostTime")
        }
        audioBuffers &+= 1
        audioFrames &+= UInt64(buffer.frameLength)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAudioTime >= 1 else { return }
        lastAudioTime = now
        let a = buffer.format.streamDescription.pointee
        audioSampleRate = a.mSampleRate.isFinite && a.mSampleRate > 0 ? a.mSampleRate : nil
        audio = "\(Self.fourCC(a.mFormatID)) · \(a.mSampleRate) Hz · \(a.mChannelsPerFrame) ch · \(a.mBitsPerChannel) bit · interleaved=\(buffer.format.isInterleaved)"
    }

    /// 將像素／音訊格式代碼轉為四字元 ASCII；無法表示時保留數值供排查。
    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }

    /// 原子讀取格式與計數；可供沒有 RTMP 的本地可控錄製使用。
    /// - Parameters:
    ///   - source: 擷取來源名稱。
    ///   - phase: 呼叫端的擷取狀態。
    /// - Returns: 不含編碼與網路資料的 Mixer 快照。
    func mixerSnapshot(source: String, phase: String) -> StreamDiagnosticsSnapshot {
        lock.lock(); defer { lock.unlock() }
        var result = StreamDiagnosticsSnapshot(source: source, session: session, phase: phase)
        result.mixerVideo = video
        result.mixerAudio = audio
        result.mixerAudioSampleRate = audioSampleRate
        result.mixerVideoFrames = videoFrames
        result.mixerAudioBuffers = audioBuffers
        result.mixerAudioFrames = audioFrames
        result.sampledUptime = ProcessInfo.processInfo.systemUptime
        return result
    }

    /// 由單一週期工作呼叫。傳輸計數依 generation 重設，不能跨重連累加。
    func snapshot(source: String, stream: RTMPStream, connection: RTMPConnection) async -> StreamDiagnosticsSnapshot {
        let video = await stream.videoSettings
        let audio = await stream.audioSettings
        let phase = String(describing: await stream.readyState)
        let pipeline = stream.videoPipelineSnapshot()
        let transport = await connection.transportDiagnostics()
        let encoding = await stream.encodingDiagnostics()
        var result = mixerSnapshot(source: source, phase: phase)
        result.encoding = encoding
        result.firstEncoderTiming = pipeline.encoder?.firstEncoderTiming
        result.lastEncoderTiming = pipeline.encoder?.lastEncoderTiming
        result.videoSettings = "\(video.profileLevel) · \(Int(video.videoSize.width))×\(Int(video.videoSize.height)) · \(video.bitRate / 1000) kbps"
        result.audioSettings = "\(audio.format.rawValue) · \(audio.bitRate / 1000) kbps"
        result.encodedVideoFrames = pipeline.encoder?.events["encoderDelivered"]?.count
        result.videoMessagesQueued = pipeline.output?.events["videoQueued"]?.count
        result.generation = transport?.generation
        result.queuedBytes = transport?.queuedBytes
        result.completedBytes = transport?.completedBytes
        result.failedBatchBytes = transport?.failedBatchBytes
        result.completedBatches = transport?.completedBatches
        result.failedBatches = transport?.failedBatches
        result.lastCompletionMilliseconds = transport?.lastCompletionMilliseconds
        result.sampledAt = Date()
        return result
    }
}
