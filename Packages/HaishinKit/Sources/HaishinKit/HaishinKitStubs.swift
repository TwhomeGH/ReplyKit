// Stub declarations for HaishinKit — SourceKit-LSP indexing only

import Foundation
import CoreMedia
import CoreVideo
import CoreGraphics

// MARK: - Core types

public enum CaptureSessionMode {
    case manual
    case automatic
}

public enum ScalingMode {
    case letterbox
}

public enum BitRateMode {
    case average
    case constant
    case variable
}

public enum AudioMixerTrackMode {
    case `default`
}

public struct VideoCodecSettings: Sendable {
    public var bitRate: Int = 6_000_000
    public var videoSize: CGSize = .init(width: 1280, height: 720)
    public var profileLevel: String = ""
    public var scalingMode: ScalingMode = .letterbox
    public var expectedFrameRate: Double = 60
    public var bitRateMode: BitRateMode = .average
    public var maxKeyFrameIntervalDuration: Int32 = 2
    public var allowFrameReordering: Bool = false
    public var isLowLatencyRateControlEnabled: Bool = true
    public init() {}
}

public struct VideoMixerSettings: Sendable {
    public var mode: VideoMixerMode = .passthrough
    public var mainTrack: UInt8 = 0
    public init() {}
}

public enum VideoMixerMode: Sendable {
    case passthrough
}

public struct AudioMixerSettings: Sendable {
    public var tracks: [UInt8: AudioMixerTrackMode] = [:]
    public init() {}
}

public struct NetworkMonitorReport: Sendable {
    public var currentBytesOutPerSecond: Int = 0
    public var totalBytesOut: Int = 0
    public var currentBytesInPerSecond: Int = 0
    public var totalBytesIn: Int = 0
    public init() {}
    public init(
        currentBytesOutPerSecond: Int,
        totalBytesOut: Int,
        currentBytesInPerSecond: Int,
        totalBytesIn: Int
    ) {
        self.currentBytesOutPerSecond = currentBytesOutPerSecond
        self.totalBytesOut = totalBytesOut
        self.currentBytesInPerSecond = currentBytesInPerSecond
        self.totalBytesIn = totalBytesIn
    }
}

public enum NetworkMonitorEvent: Sendable {
    case status(NetworkMonitorReport)
}

// MARK: - Protocols

public protocol StreamConvertible: AnyObject {
    var videoSettings: VideoCodecSettings { get async }
    func setVideoSettings(_ settings: VideoCodecSettings) async throws
}

public protocol StreamBitRateStrategy: AnyObject {
    var mamimumVideoBitRate: Int { get set }
    var mamimumAudioBitRate: Int { get set }
    func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async
}

// MARK: - MediaMixer

open class MediaMixer {
    public init(captureSessionMode: CaptureSessionMode, multiTrackAudioMixingEnabled: Bool) {}
    public func startRunning() async {}
    public func stopRunning() async {}

    public nonisolated var videoMixerSettings: VideoMixerSettings {
        get async { VideoMixerSettings() }
    }
    public func setVideoMixerSettings(_: VideoMixerSettings) async {}

    public nonisolated var audioMixerSettings: AudioMixerSettings {
        get async { AudioMixerSettings() }
    }
    public func setAudioMixerSettings(_: AudioMixerSettings) async {}

    public func addOutput(_: Any) async {}
    public func removeOutput(_: Any) async {}
    public func setSessionPreset(_: Any) async {}
    public func videoIO() -> Any { self }
}
