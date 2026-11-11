import Testing
@testable import liveAPP

struct DiagnosticAgeTests {
    @Test func formatsSubsecondAndSecondsWithoutTruncatingToZero() {
        #expect(DiagnosticAge.text(0) == "剛剛")
        #expect(DiagnosticAge.text(0.04) == "剛剛")
        #expect(DiagnosticAge.text(0.4) == "0.4 秒")
        #expect(DiagnosticAge.text(8.6) == "8.6 秒")
    }

    @Test func formatsSecondsAndMinutes() {
        #expect(DiagnosticAge.text(12.4) == "12 秒")
        #expect(DiagnosticAge.text(60) == "1 分")
        #expect(DiagnosticAge.text(75) == "1 分 15 秒")
        #expect(DiagnosticAge.text(-1) == "剛剛")
    }
}
