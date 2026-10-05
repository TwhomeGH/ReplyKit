import Foundation
import Testing
@testable import liveAPP

struct CaptureErrorDiagnosticsTests {
    @Test func endpointPreservesExplicitPortAndHidesCredentials() {
        let explicit = CaptureErrorDiagnostics.endpoint("rtmp://192.168.0.102:1936/live", key: "secret")
        #expect(explicit.contains("host=192.168.0.102 port=1936 portSource=explicit appPath=/live"))
        #expect(CaptureErrorDiagnostics.endpoint("rtmp://host/live", key: "secret").contains("port=1935 portSource=default"))
        #expect(CaptureErrorDiagnostics.endpoint("rtmps://host/live", key: "secret").contains("port=443"))
        #expect(CaptureErrorDiagnostics.endpoint("rtmp:/192.168.0.102:1936/live", key: "secret").contains("invalid"))
        let safe = CaptureErrorDiagnostics.endpoint("rtmp://user:password@host:1936/live?token=private", key: "secret")
        #expect(!safe.contains("password") && !safe.contains("private") && !safe.contains("user"))
    }

    @Test func secretsAndURLsAreRedacted() {
        let output = CaptureErrorDiagnostics.sanitize("Failed rtmp://host/live?token=private stream-secret token=hidden", secrets: ["stream-secret", "rtmp://host/live?token=private"])
        #expect(!output.contains("stream-secret"))
        #expect(!output.contains("private"))
        #expect(!output.contains("hidden"))
        #expect(!output.contains("rtmp://"))
    }
    @Test func retainsCauseWithoutDumpingUserInfo() {
        let underlying = NSError(domain: "NSPOSIXErrorDomain", code: 54)
        let error = NSError(domain: "TestRTMP", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "Connection failed",
            NSLocalizedFailureReasonErrorKey: "Peer reset",
            NSUnderlyingErrorKey: underlying,
            "unrelatedSecret": "never-dump-this"
        ])
        let output = CaptureErrorDiagnostics.describe(error, secrets: [])
        #expect(output.contains("TestRTMP"))
        #expect(output.contains("code=5"))
        #expect(output.contains("NSPOSIXErrorDomain"))
        #expect(output.contains("code=54"))
        #expect(output.contains("Peer reset"))
        #expect(!output.contains("never-dump-this"))
    }
    @Test func boundsOutputAndFlattensLines() {
        let output = CaptureErrorDiagnostics.sanitize("first\nsecond\r" + String(repeating: "x", count: 8000), secrets: [])
        #expect(output.count <= 4096)
        #expect(!output.contains("\n"))
        #expect(!output.contains("\r"))
    }
    @Test func preservesSwiftErrorCase() {
        enum Failure: Error { case requestTimedOut }
        #expect(CaptureErrorDiagnostics.describe(Failure.requestTimedOut, secrets: []).contains("requestTimedOut"))
    }
}
