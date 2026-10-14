import Foundation
import Testing
@testable import liveAPP

/// 錄製檔案大小 單元測試
struct RecordingSizeTests {

    /// 測試舊版 manifest 不會產生不存在的壓縮大小資訊。
    @Test func oldManifestHasNoInventedCompressionSize() throws {
        let item = LocalRecording(id: UUID(), created: Date())
        let encoded = try JSONEncoder().encode(item)
        var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        json.removeValue(forKey: "originalBytes")
        json.removeValue(forKey: "compressedBytes")
        json.removeValue(forKey: "compressionCompleted")
        let old = try JSONDecoder().decode(LocalRecording.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.originalBytes == nil)
        #expect(!old.sizeSummary.contains("節省"))
    }
    /// 測試尚未完成的錄製檔案不會顯示壓縮節省資訊。
    @Test func pendingOutputIsNotReportedAsSavings() {
        var item = LocalRecording(id: UUID(), created: Date())
        item.originalBytes = 100_000_000
        item.compressedBytes = 20_000_000
        item.transition(to: .finishing)
        #expect(item.sizeSummary.contains("未完成"))
        #expect(!item.sizeSummary.contains("節省"))
        item.transition(to: .ready)
        #expect(item.sizeSummary.contains("未套用"))
    }

    /// 測試成功完成的錄製檔案大小資訊會在持久化後仍然存在。
    @Test func successfulSizesSurvivePersistence() throws {
        var item = LocalRecording(id: UUID(), created: Date())
        item.originalBytes = 100_000_000
        item.compressedBytes = 20_000_000
        item.compressionCompleted = true
        item.transition(to: .ready)
        let decoded = try JSONDecoder().decode(LocalRecording.self, from: JSONEncoder().encode(item))
        #expect(decoded.originalBytes == 100_000_000)
        #expect(decoded.compressedBytes == 20_000_000)
        #expect(decoded.sizeSummary.contains("80.0 MB"))
        #expect(decoded.sizeSummary.contains("80.0%"))
    }
}
