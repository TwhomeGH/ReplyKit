import Foundation
import Testing
@testable import liveAPP

struct RuntimeDebugConfigTests {
    @Test func publishesVersionedSnapshotFromExistingKeys() throws {
        let suiteName = "RuntimeDebugConfigTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "EnableRotatelog")
        defaults.set(false, forKey: "EnableTimeDebug")
        defaults.set(true, forKey: "EnablePipelineLog")
        defaults.set(false, forKey: "EnableSocketlog")
        defaults.set(270, forKey: "Rotate")
        defaults.set(true, forKey: "RotateOriginal")

        let first = try #require(RuntimeDebugConfig.publish(to: defaults))
        #expect(first.version == 1)
        #expect(first.rotateDebug)
        #expect(!first.timeDebug)
        #expect(first.pipelineLog)
        #expect(!first.socketLog)
        #expect(first.rotation == 270)
        #expect(first.rotateOriginal)
        #expect(first.includesGeometry)

        defaults.set(false, forKey: "EnableRotatelog")
        let second = try #require(RuntimeDebugConfig.publish(to: defaults))
        #expect(second.version == 2)
        #expect(!second.rotateDebug)
        #expect(RuntimeDebugConfig.load(from: defaults) == second)
    }
}
