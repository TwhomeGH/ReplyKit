import Foundation
import Testing
@testable import liveAPP

/// 封存不覆寫同名資料，期限清理必須留下可供匯出辨識的缺口。
struct LogArchiveStoreTests {
    @Test func retentionLeavesNoticeAndKeepsRecentArchive() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appendingPathComponent("000-old.log")
        let recent = folder.appendingPathComponent("001-new.log")
        try Data("old".utf8).write(to: old)
        try Data("new".utf8).write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400)], atPath: old.path)
        try LogArchiveStore.prune(folder)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try Data(contentsOf: recent) == Data("new".utf8))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("retention-notice.txt").path))
        #expect(try LogArchiveStore.files(in: folder) == [recent])
    }
}
