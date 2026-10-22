import AVFoundation
import Testing
@testable import liveAPP

struct AudioMeterTests {
    @Test func pcmRMSPreservesSilenceAndAmplitude() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<16 { channels[channel][frame] = 0.5 }
        }
        let value = try #require(AudioMeterPCM.rms(buffer))
        #expect(abs(value - 0.5) < 0.0001)
        for channel in 0..<2 {
            for frame in 0..<16 { channels[channel][frame] = 0 }
        }
        #expect(AudioMeterPCM.rms(buffer) == 0)
        channels[0][0] = .nan
        #expect(AudioMeterPCM.rms(buffer) == nil)
    }

    @Test @MainActor func oldSessionCannotOverwriteNewMeter() {
        let model = LiveVolumeModel(observeNotifications: false)
        let now = Date()
        model.beginCapture("old")
        model.beginCapture("new")
        model.reportCapture("old", channel: "app", rms: 1, at: now)
        #expect(model.measurement("app", now: now) != nil)
        model.reportCapture("new", channel: "app", rms: 0, at: now)
        #expect(model.measurement("app", now: now) == nil)
        #expect(model.measurement("app", now: now.addingTimeInterval(4)) != nil)
        model.endCapture("old")
        #expect(!model.stopped)
        model.endCapture("new")
        model.reportCapture("new", channel: "app", rms: 1, at: now)
        #expect(model.stopped)
        #expect(model.sampledAt.isEmpty)
    }

    @Test @MainActor func stoppedCaptureDoesNotInventColdBaseline() {
        let tracker = IdleMemoryComparison(startedAt: 0)
        _ = tracker.observe(footprint: 150, captureBusy: true, replayLive: false, reason: "test", now: 1)
        let stopped = tracker.observe(footprint: 110, captureBusy: false, replayLive: false, reason: "test", now: 70)
        #expect(stopped.contains("coldIdleBaselineMB=unknown"))
        let later = tracker.observe(footprint: 100, captureBusy: false, replayLive: false, reason: "test", now: 135)
        #expect(later.contains("reachedStopSeconds=[30, 60]"))
        #expect(later.contains("deltaLastBusyMB=-50.0"))
    }
}
