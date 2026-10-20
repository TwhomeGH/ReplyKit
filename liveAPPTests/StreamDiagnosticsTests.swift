import Foundation
import Testing
import RTMPHaishinKit
@testable import liveAPP

struct StreamDiagnosticsTests {
    @Test func healthMessagesWithoutNewFieldsRemainCompatible() throws {
        let video = try JSONDecoder().decode(SocketServer.VideoHealthPayload.self,
            from: Data(#"{"status":"healthy","timeoutDelta":0}"#.utf8))
        #expect(video.latencyExceedCount == nil)
        #expect(video.latencyThresholdMs == nil)
        let audio = try JSONDecoder().decode(SocketServer.AudioHealthPayload.self,
            from: Data(#"{"status":"healthy"}"#.utf8))
        #expect(audio.sampleRate == nil)
        #expect(audio.totalLatencyMs == nil)
    }

    @Test func mixerRateIsOptionalAndSurvivesRoundTrip() throws {
        var value = StreamDiagnosticsSnapshot(source: "ReplayKit", session: UUID(), phase: "publishing")
        let old = try JSONDecoder().decode(StreamDiagnosticsSnapshot.self, from: JSONEncoder().encode(value))
        #expect(old.mixerAudioSampleRate == nil)
        #expect(old.mixerVideoFrames == nil)
        #expect(old.mixerAudioBuffers == nil)
        #expect(old.mixerAudioFrames == nil)
        #expect(old.sampledUptime == nil)
        #expect(old.encoding == nil)
        value.mixerAudioSampleRate = 48000
        value.mixerVideoFrames = 300
        value.mixerAudioBuffers = 250
        value.mixerAudioFrames = 240000
        value.sampledUptime = 100
        let decoded = try JSONDecoder().decode(StreamDiagnosticsSnapshot.self, from: JSONEncoder().encode(value))
        #expect(decoded.mixerAudioSampleRate == 48000)
        #expect(decoded.mixerVideoFrames == 300)
        #expect(decoded.mixerAudioBuffers == 250)
        #expect(decoded.mixerAudioFrames == 240000)
        #expect(decoded.sampledUptime == 100)
    }

    @Test func roundTripPreservesUnknownAndGeneration() throws {
        var value = StreamDiagnosticsSnapshot(source: "ReplayKit", session: UUID(), phase: "publishing")
        value.generation = 12
        value.completedBytes = 0
        let decoded = try JSONDecoder().decode(StreamDiagnosticsSnapshot.self, from: JSONEncoder().encode(value))
        #expect(decoded.type == "streamDiagnostics")
        #expect(decoded.generation == 12)
        #expect(decoded.completedBytes == 0)
        #expect(decoded.queuedBytes == nil)
        #expect(decoded.encodedVideoFrames == nil)
    }

    @Test func encodedSnapshotSurvivesSocketRoundTrip() async throws {
        let stream = RTMPStream(connection: RTMPConnection())
        var value = StreamDiagnosticsSnapshot(source: "ReplayKit", session: UUID(), phase: "idle")
        value.encoding = await stream.encodingDiagnostics()
        let decoded = try JSONDecoder().decode(StreamDiagnosticsSnapshot.self, from: JSONEncoder().encode(value))
        #expect(decoded.encoding?.session == value.encoding?.session)
        #expect(decoded.encoding?.generation == 0)
        #expect(decoded.encoding?.isPublishing == false)
        #expect(decoded.encoding?.video == nil)
        #expect(decoded.encoding?.audio == nil)
    }

    @Test @MainActor func oldSessionCannotOverwriteNewSnapshot() {
        let model = StreamDiagnosticsModel()
        let now = Date()
        var recent = StreamDiagnosticsSnapshot(source: "ReplayKit", session: UUID(), phase: "publishing")
        recent.sampledAt = now
        model.record(recent, now: now)
        var old = StreamDiagnosticsSnapshot(source: "ReplayKit", session: UUID(), phase: "idle")
        old.sampledAt = now.addingTimeInterval(-5)
        model.record(old, now: now)
        #expect(model.snapshots["ReplayKit"]?.session == recent.session)
        var other = recent
        other.schemaVersion = 99
        other.sampledAt = now.addingTimeInterval(1)
        model.record(other, now: now)
        #expect(model.snapshots["ReplayKit"]?.schemaVersion == 1)
    }

    /// 兩種來源的非空編碼資料可跨 JSON 傳輸；發布世代更新後不得保留舊格式。
    @Test @MainActor func actualFormatsAndResetReachBothSources() throws {
        let payload = #"{"session":"A4767886-E779-4C17-B67E-E1570F1D3EB3","generation":3,"isPublishing":true,"video":{"codec":"avc1","avcConfiguration":"64002A","width":1920,"height":1080},"audio":{"codec":"aac ","sampleRate":48000,"channels":2,"framesPerPacket":1024},"videoFormatRevision":1,"audioFormatRevision":1,"videoFormatChangedAt":100,"audioFormatChangedAt":101,"lastVideoOutputAt":105,"lastAudioOutputAt":106,"videoFrames":300,"audioPackets":250,"videoBytes":123456,"audioBytes":65432}"#
        let actual = try JSONDecoder().decode(RTMPEncodingDiagnostics.self, from: Data(payload.utf8))
        let now = Date()
        let model = StreamDiagnosticsModel()
        for source in ["ReplayKit", "ScreenCaptureKit"] {
            var value = StreamDiagnosticsSnapshot(source: source, session: UUID(), phase: "publishing")
            value.sampledAt = now
            value.encoding = actual
            let decoded = try JSONDecoder().decode(StreamDiagnosticsSnapshot.self, from: JSONEncoder().encode(value))
            model.record(decoded, now: now)
            let received = try #require(model.snapshots[source]?.encoding)
            #expect(received.video?.codec == "avc1")
            #expect(received.video?.avcConfiguration == "64002A")
            #expect(received.video?.width == 1920)
            #expect(received.video?.height == 1080)
            #expect(received.video?.fullRange == nil)
            #expect(received.video?.colorPrimaries == nil)
            #expect(received.audio?.sampleRate == 48000)
            #expect(received.audio?.channels == 2)
            #expect(received.audioPackets == 250)
            #expect(received.lastAudioOutputAt == actual.lastAudioOutputAt)
            #expect(received.videoFormatChangedAt != received.lastVideoOutputAt)

            var reset = actual
            reset.generation = 4
            reset.video = nil
            reset.audio = nil
            reset.lastVideoOutputAt = nil
            reset.lastAudioOutputAt = nil
            value.encoding = reset
            value.sampledAt = now.addingTimeInterval(5)
            model.record(value, now: value.sampledAt)
            #expect(model.snapshots[source]?.encoding?.generation == 4)
            #expect(model.snapshots[source]?.encoding?.video == nil)
            #expect(model.snapshots[source]?.encoding?.audio == nil)
        }
    }

    @Test @MainActor func bothSourcesHaveBoundedHistoryAndResetAcrossSessions() {
        let model = StreamDiagnosticsModel()
        let start = Date()
        for source in ["ReplayKit", "ScreenCaptureKit"] {
            var snapshot = StreamDiagnosticsSnapshot(source: source, session: UUID(), phase: "publishing")
            for index in 0...70 {
                snapshot.sampledAt = start.addingTimeInterval(Double(index) * 5)
                snapshot.sampledUptime = Double(index) * 5
                snapshot.mixerVideoFrames = UInt64(index * 300)
                snapshot.mixerAudioBuffers = UInt64(index * 250)
                snapshot.mixerAudioFrames = UInt64(index * 240000)
                model.record(snapshot, now: snapshot.sampledAt)
            }
            #expect(model.history[source]?.count == 60)
            #expect(model.history[source]?.last?.videoFPS == 60)
            #expect(model.history[source]?.last?.audioBuffersPerSecond == 50)
            #expect(model.history[source]?.last?.audioFramesPerSecond == 48000)
            var replacement = StreamDiagnosticsSnapshot(source: source, session: UUID(), phase: "publishing")
            replacement.sampledAt = snapshot.sampledAt.addingTimeInterval(5)
            replacement.sampledUptime = 355
            replacement.mixerVideoFrames = 50000
            model.record(replacement, now: replacement.sampledAt)
            #expect(model.history[source]?.count == 1)
            #expect(model.history[source]?.last?.videoFPS == nil)
            replacement.sampledAt = replacement.sampledAt.addingTimeInterval(30)
            replacement.sampledUptime = 385
            model.record(replacement, now: replacement.sampledAt)
            #expect(model.history[source]?.count == 1)
            #expect(model.history[source]?.last?.videoFPS == nil)
        }
    }
}
