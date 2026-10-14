import Foundation
import CoreGraphics
import Testing
@testable import liveAPP

/// 錄製壓縮 單元測試
struct RecordingCompressionTests {

    /// 測試壓縮設定的持久化與驗證行為。
    @Test func settingsValidatePersistedValues() {
        let settings = RecordingCompressionSettings(enabled: true, hevc: true, megabits: -1, longestEdge: 7, fpsLimit: 999)
        #expect(settings.megabits == 1)
        #expect(settings.longestEdge == 1920)
        #expect(settings.fpsLimit == 60)
        #expect(RecordingCompressionSettings(enabled: true, hevc: false, megabits: 99, longestEdge: 0, fpsLimit: 0).megabits == 40)
    }

    /// 測試壓縮設定的輸出尺寸計算，確保不會放大影像，並保持直向比例。
    @Test func scalingPreservesPortraitAndDoesNotUpscale() {
        let settings = RecordingCompressionSettings(enabled: true, hevc: true, megabits: 8, longestEdge: 1920, fpsLimit: 30)
        let size = settings.outputSize(CGSize(width: 1640, height: 2360))
        #expect(size == CGSize(width: 1334, height: 1920))
        #expect(settings.outputSize(CGSize(width: 1280, height: 720)) == CGSize(width: 1280, height: 720))
        #expect(settings.estimatedVideoMBPerMinute == 60)
    }

    /// 測試限制影格率的行為，確保不會產生不存在的樣本。
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

    /// 測試變動的影格間隔與無限制模式會保留原始時間戳。
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

    /// 測試缺少設定時，壓縮選項仍然保持預設值。
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

    /// 測試系統品質與自動錄製位元率是明確的選項。
    @Test func systemQualityAndAutomaticRecordingBitrateAreExplicitChoices() {
        let name = "RecordingOptions." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let initial = DirectRecordingSettings(defaults: defaults)
        #expect(!initial.automaticBitrate)
        #expect(initial.segmentSeconds == 120)
        defaults.set(true, forKey: "directRecordingAutomaticBitrate")
        defaults.set(7, forKey: "recordingSegmentSeconds")
        let automatic = DirectRecordingSettings(defaults: defaults)
        #expect(automatic.automaticBitrate)
        #expect(automatic.segmentSeconds == 120)
        defaults.set(true, forKey: "recordingCompressionSystemQuality")
        defaults.set(true, forKey: "recordingCompressionMultiPass")
        let quality = RecordingCompressionSettings.load(from: defaults)
        #expect(quality.systemQuality)
        #expect(quality.multiPass)
    }

}
