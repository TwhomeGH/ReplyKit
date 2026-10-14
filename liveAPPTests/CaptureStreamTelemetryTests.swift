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

/// 停止後的歷史快照不應被誤報為仍在工作的管線逾時。
struct CapturePipelineStatusTests {
    @Test func stoppedSnapshotDoesNotAge() {
        let timestamp = Date(timeIntervalSince1970: 100)
        let first = CapturePipelineStatus.resolve(phase: .idle, failed: false, sampledAt: timestamp, now: timestamp)
        let later = CapturePipelineStatus.resolve(phase: .idle, failed: false, sampledAt: timestamp, now: timestamp.addingTimeInterval(3600))
        #expect(first == later)
        #expect(!later.isStale)
        #expect(later.text.contains("已停止"))
    }

    @Test func onlyActiveCaptureReportsStaleData() {
        let timestamp = Date(timeIntervalSince1970: 100)
        let now = timestamp.addingTimeInterval(16)
        for phase in [CapturePhase.idle, .selecting, .starting, .stopping] {
            #expect(!CapturePipelineStatus.resolve(phase: phase, failed: false, sampledAt: timestamp, now: now).isStale)
        }
        #expect(CapturePipelineStatus.resolve(phase: .streaming, failed: false, sampledAt: timestamp, now: now).isStale)
        #expect(!CapturePipelineStatus.resolve(phase: .streaming, failed: false, sampledAt: timestamp, now: timestamp.addingTimeInterval(15)).isStale)
    }

    @Test func failedPublishCanLeaveRecordingActive() {
        let now = Date()
        let active = CapturePipelineStatus.resolve(phase: .streaming, failed: true, sampledAt: now, now: now)
        let stopped = CapturePipelineStatus.resolve(phase: .idle, failed: true, sampledAt: now, now: now)
        #expect(active.text.contains("擷取仍在運作"))
        #expect(stopped.text.contains("擷取已結束"))
        #expect(!stopped.isStale)
        #expect(CapturePipelineStatus.resolve(phase: .idle, failed: false, sampledAt: nil, now: now).text.contains("尚未開始"))
    }
}
