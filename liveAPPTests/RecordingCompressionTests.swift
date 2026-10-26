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
        #expect(settings.longestEdge == 7)
        #expect(settings.fpsLimit == 120)
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

    /// 自訂框按觀看方向縮放，直向旋轉來源須交換像素軸；不放大小片。
    @Test func customBoundsRespectDisplayOrientation() {
        let settings = RecordingCompressionSettings(enabled: true, hevc: false,
            megabits: 8, longestEdge: 0, fpsLimit: 24,
            boundingSize: CGSize(width: 1080, height: 1920))
        #expect(settings.fpsLimit == 24)
        #expect(settings.outputSize(CGSize(width: 3840, height: 2160), swapsAxes: true)
            == CGSize(width: 1920, height: 1080))
        #expect(settings.outputSize(CGSize(width: 2160, height: 3840))
            == CGSize(width: 1080, height: 1920))
        #expect(settings.outputSize(CGSize(width: 640, height: 480))
            == CGSize(width: 640, height: 480))
    }

    /// 小數 Mbps 必須傳到 Writer 使用的 bit/s，不能沿用整數相容欄位。
    @Test func fractionalBitrateReachesEncoderSettings() {
        let settings = RecordingCompressionSettings(enabled: true, hevc: false,
            megabits: 8, longestEdge: 0, fpsLimit: 0, videoBitrate: 2_500_000)
        #expect(settings.videoBitrate == 2_500_000)
        #expect(settings.estimatedVideoMBPerMinute == 18.75)
        let legacy = RecordingCompressionSettings(enabled: true, hevc: false,
            megabits: 8, longestEdge: 0, fpsLimit: 0)
        #expect(legacy.videoBitrate == 8_000_000)
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

    /// 固定畫布同時控制寬高；來源比例模式明確回傳 nil。
    @Test func recordingCanvasValidatesBothDimensions() throws {
        let name = "RecordingCanvas." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let initial = DirectRecordingSettings(defaults: defaults)
        #expect(initial.canvas == CGSize(width: 1920, height: 1080))
        #expect(!initial.autoMerge)
        defaults.set(1921, forKey: "recordingCanvasWidth")
        defaults.set(0, forKey: "recordingCanvasHeight")
        let bounded = DirectRecordingSettings(defaults: defaults)
        #expect(bounded.canvas == CGSize(width: 1920, height: 2))
        defaults.set("native", forKey: "recordingCanvasMode")
        #expect(DirectRecordingSettings(defaults: defaults).canvas == nil)
    }

}
