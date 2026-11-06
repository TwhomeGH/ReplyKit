import Foundation
import Testing
@testable import liveAPP

/// 驗證備份不混入執行狀態或憑證，且匯入失敗不部分改寫偏好。
struct SettingsBackupTests {
    @Test func excludesRuntimeAndSecrets() throws {
        let name = "SettingsBackupTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "onAudioPage")
        defaults.set("secret", forKey: "rtmpKey")
        defaults.set("rtmp://host/app?token=secret", forKey: "rtmpURL")
        defaults.set(2.0, forKey: "pipClockSeconds")
        defaults.set(true, forKey: "liveActivityEnabled")
        let backup = try SettingsBackupRegistry.capture(shared: defaults, standard: defaults, includesSecrets: false)
        #expect(backup.shared["rtmpKey"] == nil)
        #expect(backup.shared["rtmpURL"] == nil)
        #expect(backup.shared["onAudioPage"] == nil)
        #expect(backup.standard["liveActivityEnabled"] as? Bool == true)
        let decoded = try SettingsBackupDocument.decode(backup.encoded())
        #expect(decoded.shared["pipClockSeconds"] as? Double == 2)
    }

    @Test func explicitSensitiveExportAndMerge() throws {
        let name = "SettingsBackupTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("keep", forKey: "TTSVoiceIdentifier")
        let backup = SettingsBackupDocument(createdAt: Date(), includesSecrets: true,
            shared: ["rtmpKey": "restored"], standard: [:])
        try SettingsBackupRegistry.apply(backup, shared: defaults, standard: defaults)
        #expect(defaults.string(forKey: "rtmpKey") == "restored")
        #expect(defaults.string(forKey: "TTSVoiceIdentifier") == "keep")
    }

    @Test func invalidImportDoesNotPartiallyApply() throws {
        let name = "SettingsBackupTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(5.0, forKey: "pipKeepaliveSeconds")
        let backup = SettingsBackupDocument(createdAt: Date(), includesSecrets: false,
            shared: ["pipKeepaliveSeconds": 1.0, "onAudioPage": true], standard: [:])
        #expect(throws: (any Error).self) {
            try SettingsBackupRegistry.apply(backup, shared: defaults, standard: defaults)
        }
        #expect(defaults.double(forKey: "pipKeepaliveSeconds") == 5)
    }

    @Test func rejectsBooleanAsNumberAndUnflaggedSecret() {
        for values: [String: Any] in [["pipClockSeconds": true], ["rtmpKey": "secret"], ["socketListenPort": 70000]] {
            let backup = SettingsBackupDocument(createdAt: Date(), includesSecrets: false,
                shared: values, standard: [:])
            #expect(throws: (any Error).self) { try SettingsBackupRegistry.validate(backup) }
        }
    }

    @Test func automaticBackupKeepsPrevious() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = SettingsBackupDocument(createdAt: Date(), includesSecrets: false,
            shared: ["pipClockSeconds": 1], standard: [:])
        let second = SettingsBackupDocument(createdAt: Date(), includesSecrets: false,
            shared: ["pipClockSeconds": 5], standard: [:])
        _ = try SettingsBackupStorage.save(first, directory: directory)
        _ = try SettingsBackupStorage.save(second, directory: directory)
        let previous = try SettingsBackupStorage.read(directory.appendingPathComponent("settings-previous.json"))
        let latest = try SettingsBackupStorage.read(directory.appendingPathComponent("settings-latest.json"))
        #expect(previous.shared["pipClockSeconds"] as? Int == 1)
        #expect(latest.shared["pipClockSeconds"] as? Int == 5)
    }

    @Test func oversizedLatestDoesNotBlockNextSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let latest = directory.appendingPathComponent("settings-latest.json")
        try Data(repeating: 0x41, count: 2_097_153).write(to: latest)
        let next = SettingsBackupDocument(createdAt: Date(), includesSecrets: false,
            shared: ["pipClockSeconds": 5], standard: [:])
        _ = try SettingsBackupStorage.save(next, directory: directory)
        let restored = try SettingsBackupStorage.read(latest)
        #expect(restored.shared["pipClockSeconds"] as? Int == 5)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("settings-previous.json").path))
    }

    @Test func rejectsFutureVersion() throws {
        let data = Data(#"{"format":"ReplyKit.settings","version":999,"createdAt":"2026-11-06T00:00:00Z","includesSecrets":false,"shared":{},"standard":{}}"#.utf8)
        #expect(throws: (any Error).self) { try SettingsBackupDocument.decode(data) }
    }

    @Test(arguments: [0.0, 100.0])
    func preservesExistingPIPControlRange(value: Double) throws {
        let backup = SettingsBackupDocument(createdAt: Date(), includesSecrets: false,
            shared: ["fadeAlpha": value, "fadeTime": value, "scrollTime": value], standard: [:])
        let restored = try SettingsBackupDocument.decode(backup.encoded())
        #expect(restored.shared["fadeAlpha"] as? Double == value)
    }
}
