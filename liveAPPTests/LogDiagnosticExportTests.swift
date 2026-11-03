import Foundation
import Testing
@testable import liveAPP

/// 驗證日期邊界、多行續文與匯出用遮蔽，不更動原始日誌。
struct LogDiagnosticExportTests {
    @Test func chinesePeriodsAndRedaction() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Taipei"))
        let morning = try #require(LogDiagnosticExport.date(in: "2026/11/3 凌晨2:33:58: liveApp:x", zone: zone))
        let afternoon = try #require(LogDiagnosticExport.date(in: "2026/11/3 下午2:33:58: liveApp:x", zone: zone))
        #expect(afternoon.timeIntervalSince(morning) == 12 * 3600)
        let safe = LogDiagnosticExport.redacted("url=rtmp://host/live/secret token=abc password=xyz")
        #expect(!safe.contains("secret"))
        #expect(!safe.contains("abc"))
        #expect(!safe.contains("xyz"))
    }

    @Test func rangeKeepsContinuationAndExcludesOtherDay() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("source.snapshot")
        let original = "2026/11/2 下午11:59:59: liveApp:old\nold continuation\n2026/11/3 凌晨12:00:00: liveApp:new\n[BuildInfo] version=test\n2026/11/4 凌晨12:00:00: liveApp:future\nfuture continuation\n"
        try Data(original.utf8).write(to: input)
        let zone = try #require(TimeZone(identifier: "Asia/Taipei"))
        let start = try #require(LogDiagnosticExport.date(in: "2026/11/3 凌晨12:00:00: x", zone: zone))
        let output = try LogDiagnosticExport.extract(snapshot: input, start: start,
            end: start.addingTimeInterval(86399), zone: zone)
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.contains("version=test"))
        #expect(!text.contains("old continuation"))
        #expect(!text.contains("future continuation"))
        #expect(try String(contentsOf: input, encoding: .utf8) == original)
    }
}
