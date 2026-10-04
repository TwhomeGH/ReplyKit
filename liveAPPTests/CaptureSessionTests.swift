import Foundation
import Testing
@testable import liveAPP

private final class CaptureTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: Double) { lock.lock(); value += seconds; lock.unlock() }
}

struct CaptureSessionTests {
    @Test func cannotStartTwiceOrResumeAfterStop() {
        var state = CaptureSessionState()
        let token = state.begin()!
        let secondBegin = state.begin()
        #expect(secondBegin == nil)
        let started = state.transition(.starting, for: token)
        #expect(started)
        state.stopping()
        let resumedAfterStop = state.transition(.streaming, for: token)
        #expect(!resumedAfterStop)
        state.finish(token)
        #expect(state.phase == .idle)
    }
    @Test func lateCompletionCannotFinishNewSession() {
        var state = CaptureSessionState()
        let first = state.begin()!
        state.finish(first)
        let second = state.begin()!
        state.finish(first)
        #expect(state.id == second)
        let lateStart = state.transition(.starting, for: first)
        #expect(!lateStart)
        let secondStart = state.transition(.starting, for: second)
        #expect(secondStart)
        let secondStreaming = state.transition(.streaming, for: second)
        #expect(secondStreaming)
    }
    @Test func cannotSkipAuthorization() {
        var state = CaptureSessionState()
        let token = state.begin()!
        let skipped = state.transition(.streaming, for: token)
        #expect(!skipped)
        #expect(state.phase == .selecting)
    }
    @Test func mailboxEvictsOldSamplesWithinByteBudget() async {
        let queue = CaptureMailbox<Int>(budget: 10, age: 10)
        queue.offer(1, bytes: 6); queue.offer(2, bytes: 6)
        var iterator = queue.stream().makeAsyncIterator()
        #expect(await iterator.next() == 2)
        #expect(queue.summary.contains("dropped=1"))
        queue.finish()
        #expect(await iterator.next() == nil)
    }
    @Test func oversizedAndExpiredSamplesAreNotDelivered() async {
        let clock = CaptureTestClock()
        let queue = CaptureMailbox<Int>(budget: 8, clock: { clock.now() })
        queue.offer(1, bytes: 9)
        queue.offer(2, bytes: 4)
        clock.advance(0.2)
        queue.offer(3, bytes: 4)
        var iterator = queue.stream().makeAsyncIterator()
        #expect(await iterator.next() == 3)
        #expect(queue.summary.contains("dropped=2"))
        queue.finish()
    }
    @Test func finishedMailboxRejectsLateCaptureCallbacks() async {
        let queue = CaptureMailbox<Int>(budget: 10)
        queue.finish(); queue.offer(1, bytes: 1)
        var iterator = queue.stream().makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(queue.summary.contains("bytes=0/10"))
    }
    @Test func audioOwnershipProtectsRecordingCategory() {
        let ownership = CaptureAudioOwnership()
        var changes = 0
        ownership.begin()
        ownership.performUnlessCaptured { changes += 1 }
        #expect(changes == 0)
        ownership.end()
        ownership.performUnlessCaptured { changes += 1 }
        #expect(changes == 1)
    }
    @Test func sixtyFramesDoNotRequireSixtyQueuedSamples() async {
        let queue = CaptureMailbox<Int>(budget: 1)
        var iterator = queue.stream().makeAsyncIterator()
        for i in 0..<60 { queue.offer(i, bytes: 1); #expect(await iterator.next() == i) }
        #expect(queue.summary.contains("dropped=0"))
        queue.finish()
    }
    @Test func recordingOnlyDoesNotRequireNetworkSettings() {
        #expect(CaptureWorkMode.record.accepts(endpoint: "", key: ""))
        #expect(!CaptureWorkMode.record.wantsStreaming)
        #expect(CaptureWorkMode.record.wantsRecording)
        for mode in [CaptureWorkMode.stream, .streamAndRecord] {
            #expect(!mode.accepts(endpoint: "", key: ""))
            #expect(!mode.accepts(endpoint: "https://example.com", key: "secret"))
            #expect(!mode.accepts(endpoint: "rtmp://example.com/live", key: "  "))
            #expect(mode.accepts(endpoint: "rtmps://example.com/live", key: "secret"))
        }
    }
    @Test func stopDoesNotMakeRecordingShareable() {
        var item = LocalRecording(id: UUID(), created: Date())
        let toRecording = item.transition(to: .recording)
        #expect(toRecording)
        let toFinishing = item.transition(to: .finishing)
        #expect(toFinishing)
        #expect(item.phase != .ready)
        let recordingAgain = item.transition(to: .recording)
        #expect(!recordingAgain)
        let toReady = item.transition(to: .ready)
        #expect(toReady)
        let toFailed = item.transition(to: .failed)
        #expect(!toFailed)
        #expect(item.phase == .ready)
    }
    @Test func lateFinishCannotPromoteFailedOrTimedOutRecording() {
        for terminal in [RecordingPhase.failed, .interrupted] {
            var item = LocalRecording(id: UUID(), created: Date())
            let toTerminal = item.transition(to: terminal)
            #expect(toTerminal)
            let promotedToReady = item.transition(to: .ready)
            #expect(!promotedToReady)
            #expect(item.phase == terminal)
        }
    }
    @Test func relaunchPreservesCompletedFilesAndMarksUnfinishedFiles() throws {
        for phase in [RecordingPhase.recording, .finishing, .ready, .failed] {
            var original = LocalRecording(id: UUID(), created: Date())
            original.transition(to: phase)
            let data = try JSONEncoder().encode(original)
            var recovered = try JSONDecoder().decode(LocalRecording.self, from: data)
            recovered.recoverAfterRelaunch()
            #expect(recovered.id == original.id)
            #expect(recovered.phase == (phase.isTerminal ? phase : .interrupted))
        }
    }
}
