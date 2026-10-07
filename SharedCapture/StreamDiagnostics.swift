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

/// 只保存最新格式文字；每秒最多解析一次附件，不保留 sample 或 pixel buffer。
final class StreamDiagnosticsProbe: MediaMixerOutput, @unchecked Sendable {
    let videoTrackId: UInt8? = UInt8.max
    let audioTrackId: UInt8? = UInt8.max
    let session = UUID()
    private let lock = NSLock()
    private var video: String?
    private var audio: String?
    private var audioSampleRate: Double?
    private var lastVideoTime = -Double.infinity
    private var lastAudioTime = -Double.infinity

    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async {}

    func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
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
        default: range = "未判定"
        }
        video = "\(CVPixelBufferGetWidth(image))×\(CVPixelBufferGetHeight(image)) · pixel=\(Self.fourCC(pixel)) · range=\(range) · primaries=\(attachment(kCVImageBufferColorPrimariesKey)) · transfer=\(attachment(kCVImageBufferTransferFunctionKey)) · matrix=\(attachment(kCVImageBufferYCbCrMatrixKey))"
    }

    func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAudioTime >= 1 else { return }
        lastAudioTime = now
        let a = buffer.format.streamDescription.pointee
        audioSampleRate = a.mSampleRate.isFinite && a.mSampleRate > 0 ? a.mSampleRate : nil
        audio = "\(Self.fourCC(a.mFormatID)) · \(a.mSampleRate) Hz · \(a.mChannelsPerFrame) ch · \(a.mBitsPerChannel) bit · interleaved=\(buffer.format.isInterleaved)"
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }

    /// 在鎖內複製文字後才進入 await，避免阻塞影音回呼。
    private func formats() -> (String?, String?, Double?) {
        lock.lock(); defer { lock.unlock() }
        return (video, audio, audioSampleRate)
    }

    /// 由單一週期工作呼叫。傳輸計數依 generation 重設，不能跨重連累加。
    func snapshot(source: String, stream: RTMPStream, connection: RTMPConnection) async -> StreamDiagnosticsSnapshot {
        let formats = formats()
        let video = await stream.videoSettings
        let audio = await stream.audioSettings
        let phase = String(describing: await stream.readyState)
        let pipeline = stream.videoPipelineSnapshot()
        let transport = await connection.transportDiagnostics()
        var result = StreamDiagnosticsSnapshot(source: source, session: session, phase: phase)
        result.mixerVideo = formats.0
        result.mixerAudio = formats.1
        result.mixerAudioSampleRate = formats.2
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
