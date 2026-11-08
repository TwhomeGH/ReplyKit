import AVFoundation
import Testing
@testable import liveAPP

struct AudioMeterTests {
    @Test func meterUsesCommonDecibelScale() throws {
        #expect(AudioLevelPresentation.level(0) == 0)
        #expect(AudioLevelPresentation.level(1) == 1)
        #expect(AudioLevelPresentation.decibels(.nan) == nil)
        let half = try #require(AudioLevelPresentation.decibels(0.5))
        #expect(abs(half + 6.0206) < 0.001)
        #expect(AudioLevelPresentation.level(0.427) > AudioLevelPresentation.level(0.099))
        // 衰減 20 dB 應在 60 dB 量表上縮短三分之一。
        #expect(abs(AudioLevelPresentation.level(0.5) - AudioLevelPresentation.level(0.05) - 1.0 / 3) < 0.001)
    }

    @Test @MainActor func appliedGainIsSessionScoped() {
        let model = LiveVolumeModel(observeNotifications: false)
        model.beginCapture("new")
        model.reportAppliedGains("old", app: 1, mic: 1)
        #expect(model.appliedGains.isEmpty)
        model.reportAppliedGains("new", app: 0, mic: nil)
        #expect(model.appliedGains["app"] == 0)
        #expect(model.appliedGains["mic"] == nil)
        model.endCapture("new")
        model.reportAppliedGains("new", app: 1, mic: 1)
        #expect(model.appliedGains.isEmpty)
    }

    @Test @MainActor func replayAcknowledgementRejectsOldRevisionAndLocalCapture() {
        let model = LiveVolumeModel(observeNotifications: false)
        let first = ReplayVolumeApplied(schema: 1, session: "A", revision: 2, status: "applied",
                                        reportedAt: 10, app: 0, mic: 1)
        model.reportReplayApplied(first)
        #expect(model.replayApplied?.app == 0)
        model.reportReplayApplied(ReplayVolumeApplied(schema: 1, session: "A", revision: 1,
            status: "applied", reportedAt: 11, app: 1, mic: 1))
        #expect(model.replayApplied?.revision == 2)
        model.reportReplayApplied(ReplayVolumeApplied(schema: 1, session: "older", revision: 9,
            status: "applied", reportedAt: 9, app: 1, mic: 1))
        #expect(model.replayApplied?.session == "A")
        model.beginCapture("local")
        model.reportReplayApplied(first)
        #expect(model.replayApplied == nil)
    }

    @Test func sharedControlPreservesMuteAndValidatesGain() throws {
        let name = "AudioControlTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(0.0, forKey: "appVolume")
        defaults.set(0.5, forKey: "micVolume")
        defaults.set(80.0, forKey: "micAddVolume")
        let settings = AudioControlSettings(defaults: defaults)
        #expect(settings.app == 0)
        #expect(settings.mic == 0.5)
        #expect(settings.micGain == 30)
        #expect(settings.isValid)
        let roundTrip = try JSONDecoder().decode(AudioControlSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip == settings)
        let invalid = Data(#"{"schema":2,"app":0,"mic":1,"micGain":-1}"#.utf8)
        let decoded = try JSONDecoder().decode(AudioControlSettings.self, from: invalid)
        #expect(!decoded.isValid)
    }

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
