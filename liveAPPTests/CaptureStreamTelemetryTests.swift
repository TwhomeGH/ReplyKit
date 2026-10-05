import Foundation
import Testing
@testable import liveAPP

struct CaptureStreamTelemetryTests {
    @Test func separatesConfiguredAudioFromObservedPackets() {
        var state = CaptureStreamTelemetry()
        state.targetBitrate = 128000
        #expect(state.audioState() == "waiting")
        let now = Date()
        state.consume(message: "audio: format=AAC LC input=<2 ch, 44100 Hz> output=<AVAudioFormat 0x123: 2 ch, 48000 Hz, aac>", detail: nil, now: now)
        #expect(state.encoderFormat == "AAC LC · 2 ch, 48000 Hz")
        #expect(state.audioState(at: now) == "waiting")
        state.consume(message: "publish throughput", detail: "audioInputFrames=50 audioFrames=0 audioBytes=0", now: now)
        #expect(state.audioState(at: now) == "missing")
        state.consume(message: "publish throughput", detail: "audioFrames=43 audioBytes=16000", now: now)
        #expect(state.audioState(at: now) == "packets")
        #expect(state.audioState(at: now.addingTimeInterval(21)) == "stale")
    }

    @Test func preservesFailureAndResetsReconnectEvidence() {
        var state = CaptureStreamTelemetry()
        let now = Date()
        state.consume(message: "TCP connected, sending C0C1", detail: nil, now: now)
        #expect(state.stage == "handshake")
        state.consume(message: "State: ackSent => handshakeDone", detail: nil, now: now)
        #expect(state.stage == "connect")
        state.consume(message: "publish throughput", detail: "audioFrames=43", now: now)
        state.consume(message: "TCP connecting", detail: nil, now: now)
        #expect(state.audioState(at: now) == "waiting")
        state.failed = true
        state.consume(message: "Connect success", detail: nil, now: now)
        #expect(state.stage == "tcp")
    }

    @Test func ignoresMalformedAndOutOfOrderEvents() {
        var state = CaptureStreamTelemetry()
        let now = Date()
        state.consume(message: "Connect success", detail: nil, now: now)
        state.consume(message: "TCP connecting", detail: nil, now: now.addingTimeInterval(-1))
        #expect(state.stage == "publish")
        state.consume(message: "audio: format=AAC LC output=unknown", detail: nil, now: now)
        state.consume(message: "publish throughput", detail: "audioFrames=invalid", now: now)
        #expect(state.encoderFormat == nil)
        #expect(state.audioPackets == nil)
    }
}
