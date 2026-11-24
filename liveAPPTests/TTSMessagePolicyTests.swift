import Testing
@testable import liveAPP

/// TTS gating 的順序：停用、mainOnly、長度、空白。
struct TTSMessagePolicyTests {
    @Test func mainOnlyPrecedesLength() {
        let reason = TTSMessagePolicy.skipReason(
            isEnabled: true, readMainOnly: true, isMain: false,
            text: "來了", minLen: 5, force: false)
        #expect(reason == .mainOnly)
    }

    @Test func shortMainMessageIsTooShort() {
        let reason = TTSMessagePolicy.skipReason(
            isEnabled: true, readMainOnly: true, isMain: true,
            text: "來了", minLen: 5, force: false)
        #expect(reason == .tooShort)
    }

    @Test func forceAllowsShortMessage() {
        let reason = TTSMessagePolicy.skipReason(
            isEnabled: true, readMainOnly: true, isMain: true,
            text: "來了", minLen: 5, force: true)
        #expect(reason == nil)
    }

    @Test func disabledAndEmptyAreDistinct() {
        #expect(TTSMessagePolicy.skipReason(
            isEnabled: false, readMainOnly: true, isMain: true,
            text: "正常長度訊息", minLen: 5, force: false) == .disabled)
        #expect(TTSMessagePolicy.skipReason(
            isEnabled: true, readMainOnly: false, isMain: true,
            text: "   ", minLen: 5, force: true) == .empty)
    }
}
