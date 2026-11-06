import Foundation
import Testing
@testable import liveAPP

@MainActor
struct RTMPPresetStoreTests {
    private func makeStore() -> (RTMPPresetStore, UserDefaults, String) {
        let name = "RTMPPresetStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (RTMPPresetStore(defaults: defaults), defaults, name)
    }

    @Test func builtInPresetsExist() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!store.builtIn.isEmpty)
        #expect(store.builtIn.contains { $0.name == "Twitch" })
    }

    @Test func validatesOnlyRTMPEndpoints() {
        let valid = RTMPPreset(id: "a", name: "A", rtmpURL: "rtmps://host/app", note: nil)
        #expect(RTMPPresetStore.validated(valid, requireID: true) != nil)
        for url in ["http://host/app", "rtmp://", "", "rtmp:///app"] {
            let preset = RTMPPreset(id: "a", name: "A", rtmpURL: url, note: nil)
            #expect(RTMPPresetStore.validated(preset, requireID: true) == nil)
        }
    }

    @Test func userPresetsPersistAndRejectDuplicates() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(store.addUserPreset(name: "Mine", rtmpURL: "rtmp://host/live"))
        #expect(!store.addUserPreset(name: "Mine", rtmpURL: "rtmp://host/live"))
        #expect(store.userPresets.count == 1)

        let reloaded = RTMPPresetStore(defaults: defaults)
        #expect(reloaded.userPresets.count == 1)
        #expect(reloaded.userPresets.first?.rtmpURL == "rtmp://host/live")
    }

    @Test func importsEnvelopeAndSkipsInvalidItems() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }
        let data = Data(#"""
        {"version":1,"presets":[
          {"id":"x","name":"Good","rtmpURL":"rtmp://host/app"},
          {"id":"y","name":"Bad","rtmpURL":"http://host/app"}
        ]}
        """#.utf8)
        let result = store.importPresets(from: data)
        #expect(result.added == 1)
        #expect(result.skipped == 1)
        #expect(store.userPresets.first?.name == "Good")
    }

    @Test func exportRoundTripsUserPresetsOnly() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = store.addUserPreset(name: "Mine", rtmpURL: "rtmp://host/live")
        guard let data = store.exportData(),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            Issue.record("exportData should produce a JSON object")
            return
        }
        let presets = object["presets"] as? [[String: Any]]
        #expect(presets?.count == 1)
        #expect(presets?.first?["name"] as? String == "Mine")
        #expect(presets?.first?["streamKey"] == nil)
    }

    @Test func removingPresetClearsStorage() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = store.addUserPreset(name: "Mine", rtmpURL: "rtmp://host/live")
        let preset = store.userPresets[0]
        store.removeUserPreset(preset)
        #expect(store.userPresets.isEmpty)
        #expect(RTMPPresetStore(defaults: defaults).userPresets.isEmpty)
    }
}
