// Stub declarations for RTMPHaishinKit — SourceKit-LSP indexing only

import Foundation
@_exported import HaishinKit

// MARK: - RTMPConnection

open class RTMPConnection {
    public enum Error: Swift.Error {
        case requestFailed(String)
    }
    public init() {}
    open func connect(_: String) async throws {}
    open func close() async throws {}
}

// MARK: - RTMPStream

open class RTMPStream: StreamConvertible {
    public enum Error: Swift.Error {
        case requestFailed(String)
    }
    public init(connection: RTMPConnection) {}

    open func publish(_: String) async throws {}
    open func close() async throws {}
    open func setVideoInputBufferCounts(_: Int) async {}

    public var videoSettings: VideoCodecSettings {
        get async { VideoCodecSettings() }
    }
    public func setVideoSettings(_: VideoCodecSettings) async throws {}

    open func setBitRateStrategy(_: StreamBitRateStrategy?) async {}
}
