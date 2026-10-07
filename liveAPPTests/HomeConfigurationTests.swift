import Foundation
import Testing
@testable import liveAPP

struct HomeConfigurationTests {
    @Test func blankDraftDoesNotOverwriteActiveConfiguration() throws {
        let suite = "HomeConfigurationTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = StreamConfigManager(storage: defaults, endpointStorage: defaults)
        let original = StreamConfig(name: "Original", rtmpURL: "rtmp://localhost:1936/live", streamKey: "secret")
        manager.saveAndActivate(original)
        var draft = StreamConfigurationDraft(config: original)
        draft = StreamConfigurationDraft()
        #expect(draft.validatedConfig == nil)
        #expect(manager.activeConfigID == original.id)
        #expect(manager.activeConfig?.streamKey == "secret")
        #expect(defaults.string(forKey: "rtmpKey") == "secret")
        draft.name = "New"
        draft.rtmpURL = "rtmps://example.com/live"
        draft.streamKey = "new-key"
        manager.saveAndActivate(try #require(draft.validatedConfig))
        #expect(manager.configs.count == 2)
        #expect(manager.configs.first?.streamKey == "secret")
        #expect(defaults.string(forKey: "rtmpKey") == "new-key")
    }

    @Test func updatingDraftPreservesIDAndValidatesEndpoint() throws {
        let original = StreamConfig(name: "Original", rtmpURL: "rtmp://localhost:1936/live", streamKey: "key")
        var draft = StreamConfigurationDraft(config: original)
        draft.name = "Changed"
        #expect(try #require(draft.validatedConfig).id == original.id)
        draft.rtmpURL = "https://example.com/live"
        #expect(draft.validatedConfig == nil)
        draft.rtmpURL = "rtmp://"
        #expect(draft.validatedConfig == nil)
    }

    @Test func bitrateBoundsAndInvalidValues() {
        #expect(BitrateManager.normalizedMultiplier(savedBitrate: -1) == 60)
        #expect(BitrateManager.normalizedMultiplier(savedBitrate: 0) == 60)
        #expect(BitrateManager.normalizedMultiplier(savedBitrate: 1) == 10)
        #expect(BitrateManager.normalizedMultiplier(savedBitrate: 6_000_000) == 60)
        #expect(BitrateManager.normalizedMultiplier(savedBitrate: Int.max) == 200)
    }
}
