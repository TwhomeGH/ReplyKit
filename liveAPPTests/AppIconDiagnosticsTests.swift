import Testing
@testable import liveAPP

struct AppIconDiagnosticsTests {
    @Test func ipadMissingDeclarationIsDistinctFromSystemRefusal() {
        let phone: [String: Any] = ["CFBundleAlternateIcons": ["PersonalIcon": ["CFBundleIconName": "PersonalIcon"]]]
        let missing = AppIconDiagnostics(info: ["CFBundleIcons": phone], isPad: true, supported: false, current: nil)
        #expect(missing.padNames.isEmpty)
        #expect(missing.explanation.contains("缺少"))
        let declared = AppIconDiagnostics(info: ["CFBundleIcons": phone, "CFBundleIcons~ipad": phone],
            isPad: true, supported: false, current: nil)
        #expect(declared.explanation.contains("缺少此裝置的替換 PNG"))
        #expect(!declared.supported)
    }
}
