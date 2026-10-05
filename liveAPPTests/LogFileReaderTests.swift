import Foundation
import Testing
@testable import liveAPP

struct LogFileReaderTests {
    @Test func pagingAppendAndTruncate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = (0..<450).map { "中文紀錄 \($0)" }.joined(separator: "\n") + "\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        let reader = LogFileReader()
        let tail = try reader.page(url: url, start: nil, expectedGeneration: nil)
        #expect(tail.start == 250 && tail.total == 450 && tail.lines.count == 200)
        #expect(tail.lines.first == "中文紀錄 250")
        let first = try reader.page(url: url, start: 0, expectedGeneration: tail.generation)
        #expect(first.lines.first == "中文紀錄 0")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("新紀錄\n".utf8)); try handle.close()
        let appended = try reader.page(url: url, start: nil, expectedGeneration: tail.generation)
        #expect(appended.total == 451 && appended.generation == tail.generation)
        #expect(appended.lines.last == "新紀錄")
        try "清空後\n".write(to: url, atomically: true, encoding: .utf8)
        let reset = try reader.page(url: url, start: 250, expectedGeneration: tail.generation)
        #expect(reset.generation != tail.generation && reset.start == 0 && reset.total == 1)
    }
    @Test func utf8ChunkBoundariesAndUnterminatedTail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let long = String(repeating: "繁", count: 23000)
        try (long + "\n尾端").write(to: url, atomically: true, encoding: .utf8)
        let reader = LogFileReader()
        let page = try reader.page(url: url, start: 0, expectedGeneration: nil)
        #expect(page.lines == [long, "尾端"])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("續寫\n".utf8)); try handle.close()
        let next = try reader.page(url: url, start: 0, expectedGeneration: page.generation)
        #expect(next.lines == [long, "尾端續寫"])
    }
    @Test func emptyFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        let page = try LogFileReader().page(url: url, start: nil, expectedGeneration: nil)
        #expect(page.total == 0 && page.lines.isEmpty)
    }
}
