import Foundation
import Testing
@testable import liveAPP

struct VideoInputBufferSettingsTests {
    @Test func usesSourceSpecificDefaults() {
        let sck = VideoInputBufferSettings.load(from: nil, source: .screenCaptureKit)
        #expect(sck.budgetMB == 32)
        #expect(sck.durationMS == 150)
        #expect(sck.budgetBytes == 32 * 1024 * 1024)

        let replayKit = VideoInputBufferSettings.load(from: nil, source: .replayKit)
        #expect(replayKit.budgetMB == 15)
        #expect(replayKit.durationMS == 100)
    }

    @Test func readsAndClampsStoredValues() {
        let suite = "VideoInputBufferTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(20, forKey: VideoInputBufferSettings.screenCaptureKitBudgetKey)
        defaults.set(200, forKey: VideoInputBufferSettings.screenCaptureKitDurationKey)
        let value = VideoInputBufferSettings.load(from: defaults, source: .screenCaptureKit)
        #expect(value.budgetMB == 20)
        #expect(value.durationMS == 200)

        defaults.set(99, forKey: VideoInputBufferSettings.replayKitBudgetKey)
        let capped = VideoInputBufferSettings.load(from: defaults, source: .replayKit)
        #expect(capped.budgetMB == 24)
    }
}
