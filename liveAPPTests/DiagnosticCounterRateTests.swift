import Testing
@testable import liveAPP

/// 不因計數重設、介面回繞或恢復前景而顯示巨大速率。
struct DiagnosticCounterRateTests {
    @Test func usesMeasuredInterval() {
        #expect(DiagnosticCounterRate.value(current: 610, previous: 10, elapsed: 10) == 60)
        #expect(DiagnosticCounterRate.value(current: 10, previous: 10, elapsed: 1) == 0)
    }

    @Test func missingResetAndStaleAreUnknown() {
        #expect(DiagnosticCounterRate.value(current: nil, previous: 10, elapsed: 1) == nil)
        #expect(DiagnosticCounterRate.value(current: 10, previous: nil, elapsed: 1) == nil)
        #expect(DiagnosticCounterRate.value(current: 1, previous: 1000, elapsed: 1) == nil)
        for interval in [0.0, -1, 16, Double.infinity, Double.nan] {
            #expect(DiagnosticCounterRate.value(current: 610, previous: 10, elapsed: interval) == nil)
        }
    }
}
