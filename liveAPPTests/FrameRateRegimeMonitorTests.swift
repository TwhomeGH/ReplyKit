import Foundation
import Testing
@testable import liveAPP

/// A6 輸出幀率 regime：只有來源持續輸出、交付連續掉半才告警。
@Suite("FrameRateRegimeMonitor")
struct FrameRateRegimeMonitorTests {
    private func feed(_ pairs: [(Double?, Double?)],
                      monitor: inout FrameRateRegimeMonitor) -> [FrameRateRegimeMonitor.Event?] {
        pairs.map { monitor.record(sourceFPS: $0.0, outputFPS: $0.1) }
    }

    @Test("暖機後正常輸出不告警")
    func normalOutputStaysNormal() {
        var monitor = FrameRateRegimeMonitor()
        let events = feed([(60, 60), (60, 60), (60, 60), (60, 59)], monitor: &monitor)
        #expect(events.allSatisfy { $0 == nil })
        #expect(monitor.snapshot.state == .normal)
        #expect(monitor.snapshot.alertCount == 0)
    }

    @Test("來源仍輸出、交付連續掉半才告警")
    func sustainedHalfDropAlertsOnce() {
        var monitor = FrameRateRegimeMonitor()
        _ = feed([(60, 60), (60, 60), (60, 60)], monitor: &monitor)
        let firstTwo = feed([(60, 30), (60, 30)], monitor: &monitor)
        #expect(firstTwo.allSatisfy { $0 == nil })
        let third = monitor.record(sourceFPS: 60, outputFPS: 30)
        #expect(third == .regimeChange)
        #expect(monitor.snapshot.state == .degraded)
        #expect(monitor.snapshot.alertCount == 1)
    }

    @Test("靜態畫面來源也低時不告警")
    func staticSourceDoesNotAlert() {
        var monitor = FrameRateRegimeMonitor()
        _ = feed([(60, 60), (60, 60)], monitor: &monitor)
        let events = feed([(2, 2), (2, 2), (2, 2), (2, 2)], monitor: &monitor)
        #expect(events.allSatisfy { $0 == nil })
        #expect(monitor.snapshot.state == .sourceIdle)
        #expect(monitor.snapshot.alertCount == 0)
    }

    @Test("缺少交付速率時保持 unknown")
    func missingOutputIsUnknown() {
        var monitor = FrameRateRegimeMonitor()
        _ = feed([(60, 60), (60, 60)], monitor: &monitor)
        let event = monitor.record(sourceFPS: 60, outputFPS: nil)
        #expect(event == nil)
        #expect(monitor.snapshot.state == .unknown)
    }

    @Test("恢復需要連續高比例，不會在門檻附近反覆切換")
    func recoveryNeedsSustainedRatio() {
        var monitor = FrameRateRegimeMonitor()
        _ = feed([(60, 60), (60, 60), (60, 60)], monitor: &monitor)
        _ = feed([(60, 30), (60, 30), (60, 30)], monitor: &monitor)
        #expect(monitor.snapshot.state == .degraded)

        let firstTwo = feed([(60, 60), (60, 60)], monitor: &monitor)
        #expect(firstTwo.allSatisfy { $0 == nil })
        let third = monitor.record(sourceFPS: 60, outputFPS: 60)
        #expect(third == .recovered)
        #expect(monitor.snapshot.state == .normal)
    }
}
