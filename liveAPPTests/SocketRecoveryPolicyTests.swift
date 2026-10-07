import Testing
@testable import liveAPP

struct SocketRecoveryPolicyTests {
    @Test func stoppedServiceRejectsHintsInEveryState() {
        for state in SocketRecoveryPolicy.ListenerState.allCases {
            #expect(SocketRecoveryPolicy.action(state: state, wantsRunning: false, blocked: false,
                changingPort: false, retryScheduled: false) == .stopped)
        }
    }

    @Test func healthyAndStartingListenersArePreserved() {
        for state in [SocketRecoveryPolicy.ListenerState.ready, .starting, .waiting] {
            #expect(SocketRecoveryPolicy.action(state: state, wantsRunning: true, blocked: false,
                changingPort: false, retryScheduled: true) == .preserve)
        }
    }

    @Test func retryIsCoalescedUntilFailureCanBeRecovered() {
        for state in [SocketRecoveryPolicy.ListenerState.missing, .failed, .cancelled] {
            #expect(SocketRecoveryPolicy.action(state: state, wantsRunning: true, blocked: false,
                changingPort: false, retryScheduled: false) == .schedule)
            #expect(SocketRecoveryPolicy.action(state: state, wantsRunning: true, blocked: false,
                changingPort: false, retryScheduled: true) == .coalesced)
        }
    }

    @Test func portChangeAndOccupiedPortPreventAutomaticRestart() {
        #expect(SocketRecoveryPolicy.action(state: .failed, wantsRunning: true, blocked: false,
            changingPort: true, retryScheduled: false) == .deferred)
        #expect(SocketRecoveryPolicy.action(state: .missing, wantsRunning: true, blocked: true,
            changingPort: false, retryScheduled: false) == .blocked)
    }

    @Test func cooldownDefersInsteadOfDroppingRetry() {
        #expect(SocketRecoveryPolicy.delay(now: 101, lastAttempt: 100, minimum: 0) == 2)
        #expect(SocketRecoveryPolicy.delay(now: 104, lastAttempt: 100, minimum: 0) == 0)
        #expect(SocketRecoveryPolicy.delay(now: 104, lastAttempt: 100, minimum: 1.5) == 1.5)
        #expect(SocketRecoveryPolicy.delay(now: 100, lastAttempt: nil, minimum: 0) == 0)
    }
}
