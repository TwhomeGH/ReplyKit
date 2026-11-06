import Testing
@testable import liveAPP

struct AppIconDiagnosticsTests {
    @Test func ipadMissingDeclarationIsDistinctFromSystemRefusal() {
        let phone: [String: Any] = ["CFBundleAlternateIcons": ["PersonalIcon": ["CFBundleIconName": "PersonalIcon"]]]
        let missing = AppIconDiagnostics(info: ["CFBundleIcons": phone], isPad: true, supported: false, current: nil)
        #expect(missing.padNames.isEmpty)
        #expect(!missing.padIconsPresent)
        #expect(missing.explanation.contains("CFBundleIcons~ipad"))
        let declared = AppIconDiagnostics(info: ["CFBundleIcons": phone, "CFBundleIcons~ipad": phone],
            isPad: true, supported: false, current: nil)
        #expect(declared.padIconsPresent)
        #expect(declared.explanation.contains("缺少此裝置的替換 PNG"))
        #expect(!declared.supported)
    }

    @Test func reportsVersionBuildAndFamilyPresence() {
        let info: [String: Any] = [
            "CFBundleShortVersionString": "17.3.0",
            "CFBundleVersion": "123",
            "CFBundleIdentifier": "nuclear.liveAPP",
            "UIDeviceFamily": [1, 2],
            "CFBundleIcons": ["CFBundleAlternateIcons": ["PersonalIcon": [:]]],
            "CFBundleIcons~ipad": ["CFBundleAlternateIcons": ["PersonalIcon": [:]]],
        ]
        let diagnostics = AppIconDiagnostics(info: info, isPad: true, supported: false, current: nil)
        #expect(diagnostics.version == "17.3.0")
        #expect(diagnostics.build == "123")
        #expect(diagnostics.bundleID == "nuclear.liveAPP")
        #expect(diagnostics.deviceFamily == "1,2")
        #expect(diagnostics.phoneIconsPresent)
        #expect(diagnostics.padIconsPresent)
    }
}
