import Testing
@testable import liveAPP

/// 確保舊值與損壞設定不會恢復高頻更新或產生無效睡眠時間。
struct LiveActivitySettingsTests {
    @Test(arguments: [0, -1, 5, 299, 999999])
    func invalidIntervalUsesFiveMinutes(value: Int) {
        #expect(LiveActivitySettings.validatedInterval(value) == 300)
    }

    @Test(arguments: [60, 300, 600, 900])
    func supportedIntervalIsPreserved(value: Int) {
        #expect(LiveActivitySettings.validatedInterval(value) == value)
    }
}
