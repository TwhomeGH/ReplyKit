import Testing
@testable import liveAPP

/// 不合法偏好不能造成忙迴圈或無限等待。
struct PIPDisplaySettingsTests {
    @Test(arguments: [0.0, -1.0, 3.0, Double.infinity, Double.nan])
    func invalidClockUsesOneSecond(value: Double) {
        #expect(PIPDisplaySettings.validatedClock(value) == 1)
    }
    @Test(arguments: [1.0, 2.0, 5.0])
    func supportedClockIsPreserved(value: Double) {
        #expect(PIPDisplaySettings.validatedClock(value) == value)
    }
}
