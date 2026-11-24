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

    @Test("stale episode 結束後只發一次 flush")
    func flushesAfterStaleEpisode() throws {
        let monitor = CaptureContentAgeMonitor(threshold: 0.2, warmup: 0)
        let stale = monitor.evaluate(age: 0.5, now: 10)
        #expect(stale.drop == true)

        let fresh = monitor.evaluate(age: 0.1, now: 10.6)
        #expect(fresh.drop == false)
        #expect(fresh.event?.contains("event=flush") == true)
        #expect(fresh.event?.contains("dropped=1") == true)
        #expect(monitor.flushCount == 1)
        // 10.6 - 10 在 Double 上是 0.5999999999999996；時間差不能用精確相等比較。
        let flush = try #require(monitor.lastFlush)
        #expect(flush.dropped == 1)
        #expect(abs(flush.lag - 0.5) < 1e-9)
        #expect(abs(flush.gap - 0.6) < 1e-9)

        let another = monitor.evaluate(age: 0.1, now: 10.7)
        #expect(another.event == nil)
        #expect(monitor.flushCount == 1)
        #expect(monitor.summary.contains("flushes=1"))
    }

    @Test("沒有 stale 的長間隔不算 flush，只記 maxFrameGap")
    func longGapWithoutDropsDoesNotFlush() {
        let monitor = CaptureContentAgeMonitor(threshold: 0.2, warmup: 0)
        _ = monitor.evaluate(age: 0.1, now: 10)
        let resumed = monitor.evaluate(age: 0.1, now: 15)
        #expect(resumed.event == nil)
        #expect(monitor.flushCount == 0)
        #expect(monitor.summary.contains("maxFrameGap=5.000"))
    }
}
