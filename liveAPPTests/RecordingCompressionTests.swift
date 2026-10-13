import Foundation
import CoreGraphics
import Testing
@testable import liveAPP

struct RecordingCompressionTests {
    @Test func settingsValidatePersistedValues() {
        let settings = RecordingCompressionSettings(enabled: true, hevc: true, megabits: -1, longestEdge: 7, fpsLimit: 999)
        #expect(settings.megabits == 1)
        #expect(settings.longestEdge == 1920)
        #expect(settings.fpsLimit == 60)
        #expect(RecordingCompressionSettings(enabled: true, hevc: false, megabits: 99, longestEdge: 0, fpsLimit: 0).megabits == 40)
    }

    @Test func scalingPreservesPortraitAndDoesNotUpscale() {
        let settings = RecordingCompressionSettings(enabled: true, hevc: true, megabits: 8, longestEdge: 1920, fpsLimit: 30)
        let size = settings.outputSize(CGSize(width: 1640, height: 2360))
        #expect(size == CGSize(width: 1334, height: 1920))
        #expect(settings.outputSize(CGSize(width: 1280, height: 720)) == CGSize(width: 1280, height: 720))
        #expect(settings.estimatedVideoMBPerMinute == 60)
    }

    @Test func limiterDropsAlternateFramesWithoutInventingSamples() {
        var limiter = RecordingFrameRateLimiter(limit: 30)
        let accepted = (0..<60).map { Double($0) / 60 }.filter { limiter.accepts(seconds: $0) }
        #expect(accepted.count == 30)
        #expect(accepted.first == 0)
        // mutating 呼叫先執行，避免 #expect 展開成不可變接收者。
        let acceptsInvalidTime = limiter.accepts(seconds: .nan)
        let acceptsEarlierTime = limiter.accepts(seconds: 0)
        #expect(!acceptsInvalidTime)
        #expect(!acceptsEarlierTime)
    }

    @Test func variableCadenceAndUnlimitedModeKeepOriginalTimes() {
        var limiter = RecordingFrameRateLimiter(limit: 30)
        let times = [0.0, 0.1, 0.8, 2.0]
        let accepted = times.filter { limiter.accepts(seconds: $0) }
        #expect(accepted == times)
        var unlimited = RecordingFrameRateLimiter(limit: 0)
        let acceptsFirst = unlimited.accepts(seconds: 0)
        let acceptsNext = unlimited.accepts(seconds: 0.001)
        #expect(acceptsFirst)
        #expect(acceptsNext)
    }

    @Test func missingSettingsKeepCompressionOptIn() {
        let name = "RecordingCompressionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = RecordingCompressionSettings.load(from: defaults)
        #expect(!settings.enabled)
        #expect(settings.hevc)
        #expect(settings.megabits == 8)
        #expect(settings.fpsLimit == 60)
    }
}
