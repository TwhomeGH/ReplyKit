import Testing
@testable import liveAPP

/// `CaptureContentAgeMonitor` 的內容年齡閘門：只看可信抓幀時間，沒有時間時不丟幀。
struct CaptureContentAgeMonitorTests {
    @Test("低於門檻保留，並累計取樣")
    func keepsFreshFrame() {
        let monitor = CaptureContentAgeMonitor(threshold: 0.2, warmup: 0)
        let decision = monitor.evaluate(age: 0.1, now: 10)
        #expect(decision.drop == false)
        #expect(decision.event == nil)
        #expect(monitor.summary.contains("samples=1"))
    }

    @Test("暖機後超過門檻才丟棄，事件最多每 30 秒一則")
    func dropsStaleAfterWarmup() {
        let monitor = CaptureContentAgeMonitor(threshold: 0.2, warmup: 1)
        let warmup = monitor.evaluate(age: 0.5, now: 10)
        #expect(warmup.drop == false)

        let firstDrop = monitor.evaluate(age: 0.25, now: 11.1)
        #expect(firstDrop.drop == true)
        #expect(firstDrop.event?.contains("contentAgeDrop") == true)

        let throttled = monitor.evaluate(age: 0.3, now: 12)
        #expect(throttled.drop == true)
        #expect(throttled.event == nil)

        let nextWindow = monitor.evaluate(age: 0.3, now: 42)
        #expect(nextWindow.drop == true)
        #expect(nextWindow.event != nil)
        #expect(monitor.summary.contains("contentAgeDropped=3"))
    }

    @Test("沒有抓幀時間時永不丟幀，只計入 clockMissing")
    func missingClockNeverDrops() {
        let monitor = CaptureContentAgeMonitor(threshold: 0.2, warmup: 0)
        let decision = monitor.evaluate(age: nil, now: 10)
        #expect(decision.drop == false)
        #expect(decision.event == nil)
        #expect(monitor.summary.contains("clockMissing=1"))
    }

    @Test("負年齡夾為 0，未知欄位不假裝成 0")
    func clampsNegativeAge() {
        let monitor = CaptureContentAgeMonitor(threshold: 0.2, warmup: 0)
        _ = monitor.evaluate(age: -5, now: 10)
        #expect(monitor.summary.contains("lastAge=0.000"))
        #expect(monitor.summary.contains("maxAge=0.000"))
    }
}
