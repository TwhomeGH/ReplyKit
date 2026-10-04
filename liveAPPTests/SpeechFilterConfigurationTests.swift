import Foundation
import Testing
@testable import liveAPP

struct SpeechFilterConfigurationTests {
    private func decode(_ json: String) throws -> SpeechFilterConfiguration {
        try SpeechFilterConfiguration.decode(Data(json.utf8))
    }
    private func rejects(_ json: String) -> Bool {
        do { _ = try decode(json); return false } catch { return true }
    }
    @Test func legacyDictionaryHasStableOrder() throws {
        let value = try decode(#"{"blockKeywords":["廣告"],"replaceKeywords":{"B":"C","A":"B"},"removeURLs":false}"#)
        #expect(value.replaceKeywords.map(\.word) == ["A", "B"])
        #expect(value.removeURLs == false)
        #expect(value.removeEmoji == nil)
    }
    @Test func arrayOrderSurvivesRoundTrip() throws {
        let value = try decode(#"{"version":1,"blockKeywords":[],"replaceKeywords":[{"word":"B","replacement":"C"},{"word":"A","replacement":"B"}]}"#)
        let restored = try SpeechFilterConfiguration.decode(value.encoded())
        #expect(restored == value)
        #expect(restored.replaceKeywords.map(\.word) == ["B", "A"])
    }
    @Test func invalidFilesAreRejected() {
        #expect(rejects(#"{"version":2,"blockKeywords":[],"replaceKeywords":[]}"#))
        #expect(rejects(#"{"blockKeywords":[" "],"replaceKeywords":[]}"#))
        #expect(rejects(#"{"blockKeywords":[],"replaceKeywords":[{"word":"","replacement":"x"}]}"#))
        #expect(rejects(#"{"blockKeywords":[],"replaceKeywords":[],"removeURLs":"false"}"#))
        #expect(rejects(#"{"unrelated":true}"#))
        #expect(rejects("not json"))
        #expect(rejects(String(repeating: " ", count: SpeechFilterConfiguration.maximumBytes + 1)))
    }
    @Test func duplicatesNormalizeButConflictingFileIsRejected() throws {
        let value = try decode(#"{"blockKeywords":["A","A"],"replaceKeywords":[{"word":"B","replacement":""},{"word":"B","replacement":""}]}"#)
        #expect(value.blockKeywords == ["A"])
        #expect(value.replaceKeywords.count == 1)
        #expect(rejects(#"{"blockKeywords":[],"replaceKeywords":[{"word":"B","replacement":"C"},{"word":"B","replacement":"D"}]}"#))
    }
    @Test func mergeResolvesConflictsWithoutChangingFlagsOrOrder() throws {
        let current = try decode(#"{"blockKeywords":["old"],"replaceKeywords":{"A":"B"},"removeURLs":true}"#)
        let incoming = try decode(#"{"blockKeywords":["old","new"],"replaceKeywords":[{"word":"A","replacement":"C"},{"word":"D","replacement":"E"}],"removeURLs":false}"#)
        #expect(current.conflicts(with: incoming) == ["A"])
        let keep = try current.merging(incoming, useIncomingConflicts: false)
        let overwrite = try current.merging(incoming, useIncomingConflicts: true)
        #expect(keep.blockKeywords == ["old", "new"])
        #expect(keep.replaceKeywords.map(\.word) == ["A", "D"])
        #expect(keep.replaceKeywords[0].replacement == "B")
        #expect(overwrite.replaceKeywords[0].replacement == "C")
        #expect(overwrite.removeURLs == true)
        #expect(current.replaceKeywords.count == 1)
    }
    @Test func exportAndBackupNeverOverwriteEachOther() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let value = try decode(#"{"blockKeywords":["測試"],"replaceKeywords":{"你好":"您好"}}"#)
        let first = try value.write(to: directory)
        let second = try value.write(to: directory)
        let backup = try value.write(to: directory, backup: true)
        #expect(first != second && second != backup)
        #expect(backup.lastPathComponent.hasPrefix("tts-filters-backup-"))
        #expect(try SpeechFilterConfiguration.decode(Data(contentsOf: first)) == value)
        #expect(try SpeechFilterConfiguration.decode(Data(contentsOf: backup)) == value)
    }
    @Test func managerPreservesSettingsAndReplacementOrderAcrossReload() throws {
        let suite = "SpeechFilterTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["blockKeywords": ["old"], "replaceKeywords": ["A": "B"], "removeEmoji": false], forKey: "SpeechFilterSettings")
        let manager = SpeechFilterManager(defaults: defaults)
        #expect(manager.blockKeywords == ["old"])
        #expect(manager.replaceKeywords["A"] == "B")
        #expect(!manager.removeEmoji)
        let value = try decode(#"{"blockKeywords":[],"replaceKeywords":[{"word":"B","replacement":"C"},{"word":"A","replacement":"B"}]}"#)
        try manager.apply(value)
        let reopened = SpeechFilterManager(defaults: defaults)
        #expect(reopened.orderedReplacementKeys == ["B", "A"])
        #expect(reopened.processMessage("A") == "B")
        #expect(!reopened.removeEmoji)
    }
    @Test func failedBackupDoesNotModifyCurrentSettings() throws {
        let suite = "SpeechFilterTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = SpeechFilterManager(defaults: defaults)
        manager.blockKeywords = ["keep"]
        let original = manager.configuration
        let incoming = try decode(#"{"blockKeywords":["new"],"replaceKeywords":[]}"#)
        let missingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var failed = false
        do { _ = try manager.importConfiguration(incoming, replace: true, useIncomingConflicts: false, directory: missingDirectory) }
        catch { failed = true }
        #expect(failed)
        #expect(manager.configuration == original)
        #expect(SpeechFilterManager(defaults: defaults).configuration == original)
    }
    @Test func successfulImportBacksUpThePreviousConfiguration() throws {
        let suite = "SpeechFilterTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let manager = SpeechFilterManager(defaults: defaults)
        manager.blockKeywords = ["old"]
        let original = manager.configuration
        let incoming = try decode(#"{"blockKeywords":["new"],"replaceKeywords":[],"removeURLs":false}"#)
        let backup = try manager.importConfiguration(incoming, replace: true, useIncomingConflicts: false, directory: directory)
        #expect(try SpeechFilterConfiguration.decode(Data(contentsOf: backup)) == original)
        #expect(manager.blockKeywords == ["new"])
        #expect(!manager.removeURLs)
    }
    @Test func enabledStatesRoundTripAndParticipateInMergeConflicts() throws {
        let current = try decode(#"{"blockKeywords":["X"],"replaceKeywords":{"A":"B"}}"#)
        let incoming = try decode(#"{"blockKeywords":[{"word":"X","enabled":false}],"replaceKeywords":[{"word":"A","replacement":"B","enabled":false}]}"#)
        #expect(try SpeechFilterConfiguration.decode(incoming.encoded()) == incoming)
        #expect(current.blockConflicts(with: incoming) == ["X"])
        #expect(current.conflicts(with: incoming) == ["A"])
        let keep = try current.merging(incoming, useIncomingConflicts: false)
        let imported = try current.merging(incoming, useIncomingConflicts: true)
        #expect(keep.disabledBlockKeywords.isEmpty && keep.replaceKeywords[0].enabled)
        #expect(imported.disabledBlockKeywords == ["X"] && !imported.replaceKeywords[0].enabled)
        #expect(rejects(#"{"blockKeywords":[{"word":"X","enabled":"false"}],"replaceKeywords":[]}"#))
        #expect(rejects(#"{"blockKeywords":[{"word":"X","enabled":false},{"word":"X","enabled":true}],"replaceKeywords":[]}"#))
    }
    @Test func disabledRulesRemainStoredButDoNotProcessText() throws {
        let suite = "SpeechFilterTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = SpeechFilterManager(defaults: defaults)
        let value = try decode(#"{"blockKeywords":[{"word":"X","enabled":false}],"replaceKeywords":[{"word":"A","replacement":"B","enabled":false}]}"#)
        try manager.apply(value)
        #expect(manager.processMessage("XA") == "XA")
        let reopened = SpeechFilterManager(defaults: defaults)
        #expect(reopened.processMessage("XA") == "XA")
        #expect(reopened.configuration.disabledBlockKeywords == ["X"])
        reopened.disabledBlockKeywords.remove("X")
        reopened.disabledReplacementKeywords.remove("A")
        #expect(reopened.processMessage("XA") == "B")
    }
}
