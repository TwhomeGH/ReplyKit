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

    @Test func updatesNameAndURLInPlace() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = store.addUserPreset(name: "Mine", rtmpURL: "rtmp://host/old")
        let original = store.userPresets[0]
        let updated = store.updateUserPreset(id: original.id, name: "Renamed",
                                             rtmpURL: "rtmp://host/new")
        #expect(updated?.id == original.id)
        #expect(updated?.name == "Renamed")
        #expect(updated?.rtmpURL == "rtmp://host/new")
        #expect(store.userPresets.count == 1)
        let reloaded = RTMPPresetStore(defaults: defaults)
        #expect(reloaded.userPresets.first?.name == "Renamed")
        #expect(reloaded.userPresets.first?.rtmpURL == "rtmp://host/new")
    }

    @Test func updateRejectsDuplicateAndInvalidValues() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = store.addUserPreset(name: "First", rtmpURL: "rtmp://host/one")
        _ = store.addUserPreset(name: "Second", rtmpURL: "rtmp://host/two")
        let second = store.userPresets[1]
        #expect(store.updateUserPreset(id: second.id, name: "First",
                                       rtmpURL: "rtmp://host/one") == nil)
        #expect(store.updateUserPreset(id: second.id, name: "Second",
                                       rtmpURL: "http://host/two") == nil)
        #expect(store.userPresets[1].rtmpURL == "rtmp://host/two")
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
