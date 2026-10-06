import Foundation
import Testing
@testable import liveAPP

struct StreamDiagnosticsTests {
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
}
