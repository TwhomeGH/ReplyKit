#if os(iOS)
import Foundation
import Testing
@testable import liveAPP

@MainActor struct RecordingLibraryTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RecordingLibraryTests-" + UUID().uuidString, isDirectory: true)
    }
    @Test func relaunchLoadsCompletedAndInterruptedRecordings() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = RecordingLibrary(directory: directory)
        let complete = try library.create()
        let pending = try library.create()
        library.update(complete.id, phase: .ready, duration: 3.5, bytes: 42)
        library.update(pending.id, phase: .recording, duration: 1, bytes: 12)
        let reopened = RecordingLibrary(directory: directory)
        #expect(reopened.errorMessage == nil)
        #expect(reopened.recordings.count == 2)
        let ready = reopened.recordings.first { $0.id == complete.id }
        #expect(ready?.phase == .ready)
        #expect(ready?.duration == 3.5)
        #expect(ready?.bytes == 42)
        #expect(reopened.recordings.first { $0.id == pending.id }?.phase == .interrupted)
    }
    @Test func deletionPreservesActiveFilesAndRemovesFinishedFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = RecordingLibrary(directory: directory)
        let item = try library.create()
        let url = library.fileURL(for: item.id)
        try Data([1, 2, 3]).write(to: url)
        try library.delete(item)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(library.recordings.count == 1)
        library.update(item.id, phase: .failed, duration: 0, bytes: 3)
        try library.delete(library.recordings[0])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(RecordingLibrary(directory: directory).recordings.isEmpty)
    }
    @Test func malformedManifestDoesNotHideOtherRecordings() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = RecordingLibrary(directory: directory)
        let item = try library.create()
        let damaged = directory.appendingPathComponent(UUID().uuidString + ".json")
        try Data("invalid json".utf8).write(to: damaged)
        let reopened = RecordingLibrary(directory: directory)
        #expect(reopened.errorMessage != nil)
        #expect(reopened.recordings.count == 1)
        #expect(reopened.recordings.first?.id == item.id)
        #expect(FileManager.default.fileExists(atPath: damaged.path))
    }
}
#endif
