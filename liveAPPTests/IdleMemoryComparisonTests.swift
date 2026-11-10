import Testing
@testable import liveAPP

/// 使用可控時間核對同程序基準，不等待真實背景計時器。
@MainActor
struct IdleMemoryComparisonTests {
    @Test func persistedReplayStatusDoesNotInvalidateLocalBaseline() {
        let model = IdleMemoryComparison(startedAt: 0)
        _ = model.observe(footprint: 20, captureBusy: false, replayLive: true, reason: "app.start", now: 0)
        let result = model.observe(footprint: 30, captureBusy: false, replayLive: true, reason: "periodic", now: 60)
        #expect(result.contains("coldIdleBaselineMB=30.0"))
        #expect(result.contains("everObservedCapture=false"))
    }

    @Test func delayedSampleDoesNotInventMilestoneMeasurements() {
        let model = IdleMemoryComparison(startedAt: 0)
        _ = model.observe(footprint: 20, captureBusy: false, replayLive: false, reason: "start", now: 0)
        _ = model.observe(footprint: 100, captureBusy: true, replayLive: false, reason: "busy", now: 10)
        _ = model.observe(footprint: 60, captureBusy: false, replayLive: false, reason: "stop", now: 20)
        let result = model.observe(footprint: 50, captureBusy: false, replayLive: false, reason: "foreground", now: 330)
        #expect(result.contains("preCaptureSampleMB=20.0"))
        #expect(result.contains("warmIdleBaselineMB=20.0"))
        #expect(result.contains("deltaWarmIdleMB=30.0"))
        #expect(result.contains("reachedStopSeconds=[300]"))
        #expect(result.contains("missedStopSeconds=[30, 60, 120]"))
    }

    @Test func warmIdleUpdatesOnEachCaptureStart() {
        let model = IdleMemoryComparison(startedAt: 0)
        _ = model.observe(footprint: 20, captureBusy: false, replayLive: false, reason: "idle", now: 0)
        _ = model.observe(footprint: 40, captureBusy: true, replayLive: false, reason: "busy", now: 10)
        _ = model.observe(footprint: 50, captureBusy: false, replayLive: false, reason: "stop", now: 20)
        _ = model.observe(footprint: 70, captureBusy: true, replayLive: false, reason: "busy2", now: 30)
        let result = model.observe(footprint: 80, captureBusy: true, replayLive: false, reason: "busy3", now: 40)
        #expect(result.contains("warmIdleBaselineMB=50.0"))
        #expect(result.contains("deltaWarmIdleMB=30.0"))
    }
}
