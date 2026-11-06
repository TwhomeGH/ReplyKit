import Foundation
import Testing
@testable import liveAPP

/// 搬移不可覆蓋新庫；失敗時回傳舊庫，讓 App 仍能分享原始影片。
struct RecordingStorageMigrationTests {
    @Test(arguments: [false, true])
    func movesWithoutOverwriting(existing: Bool) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("private/ScreenRecordings")
        let new = root.appendingPathComponent("Documents/ScreenRecordings")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        let bytes = Data("old-recording".utf8)
        try bytes.write(to: old.appendingPathComponent("clip.mp4"))
        if existing {
            try fm.createDirectory(at: new, withIntermediateDirectories: true)
            try Data("new-recording".utf8).write(to: new.appendingPathComponent("clip.mp4"))
        }
        let result = RecordingStorageMigration.migrate(legacy: old, destination: new)
        #expect(result.warning == nil)
        let moved = existing ? new.appendingPathComponent("PreviousLibrary/clip.mp4") : new.appendingPathComponent("clip.mp4")
        #expect(try Data(contentsOf: moved) == bytes)
        #expect(!fm.fileExists(atPath: old.path))
        if existing { #expect(try Data(contentsOf: new.appendingPathComponent("clip.mp4")) == Data("new-recording".utf8)) }
    }

    @Test func conflictPreservesPrivateLibrary() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("private")
        let new = root.appendingPathComponent("shared")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createDirectory(at: new.appendingPathComponent("PreviousLibrary"), withIntermediateDirectories: true)
        let result = RecordingStorageMigration.migrate(legacy: old, destination: new)
        #expect(result.warning != nil)
        #expect(result.readableDirectories.contains(old))
        #expect(fm.fileExists(atPath: old.path))
    }
}
