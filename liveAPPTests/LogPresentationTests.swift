import Foundation
import Testing
@testable import liveAPP

struct LogPresentationTests {
    @Test func normalCaptureStatisticsAreNotSuccessOrWarning() {
        #expect(LogPresentation("[CaptureSource] capturePhase=streaming video{accepted=917 dropped=0}").severity == .info)
        #expect(LogPresentation("清除子母錯誤疊加層").severity == .info)
    }
    @Test func explicitFailuresAndDropsAreClassified() {
        #expect(LogPresentation("[CaptureError] stage=rtmp.publish code=5").severity == .error)
        #expect(LogPresentation("[CaptureSource] dropped=12").severity == .warning)
        #expect(LogPresentation("[CaptureSource] publishPhase=published").severity == .success)
        #expect(LogPresentation("[CaptureSource] publishPhase=failed").severity == .error)
    }
    @Test func sourceAndSearchMustBothMatch() {
        let message = "[CaptureError] session=ABC stage=rtmp.publish"
        let value = LogPresentation(message)
        #expect(value.matches(message, severityFilter: "issues", sourceFilter: "Capture", query: "abc"))
        #expect(!value.matches(message, severityFilter: "issues", sourceFilter: "Socket", query: "abc"))
        #expect(!value.matches(message, severityFilter: "success", sourceFilter: "all", query: ""))
    }
}
