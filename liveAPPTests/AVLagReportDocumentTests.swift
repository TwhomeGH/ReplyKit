import Foundation
import Testing
@testable import liveAPP

/// AV Lag 報告的錄影綁定：新欄位可 round-trip，舊 schema 仍可解碼。
@Suite("AVLagReportDocument recording binding")
struct AVLagReportDocumentTests {
    private func document() -> AVLagReportDocument {
        let start = Date(timeIntervalSince1970: 1_000)
        return AVLagReportDocument(
            session: "session-1",
            startedAt: start,
            endedAt: start.addingTimeInterval(120),
            segmentIndex: 0,
            segmentStartedAt: start,
            segmentEndedAt: start.addingTimeInterval(120),
            complete: true,
            sessionComplete: true,
            truncatedBefore: false,
            recordingGroup: "group-1",
            recordingStartedAt: start.addingTimeInterval(0.2),
            recordingEndedAt: start.addingTimeInterval(119.8),
            completionReason: "recordingEnded",
            sampleCount: 0,
            samples: [])
    }

    @Test("錄影群組與完成原因可編碼再解碼")
    func roundTripsRecordingBinding() throws {
        let decoded = try AVLagReportDocument.decoded(from: document().encoded())
        #expect(decoded.schema == 3)
        #expect(decoded.recordingGroup == "group-1")
        #expect(decoded.completionReason == "recordingEnded")
        #expect(decoded.recordingStartedAt != nil)
        #expect(decoded.recordingEndedAt != nil)
    }

    @Test("舊 schema 沒有錄影欄位時解成 nil，不破壞報告")
    func decodesLegacyWithoutRecordingFields() throws {
        var object = try #require(
            JSONSerialization.jsonObject(with: document().encoded()) as? [String: Any])
        object["schema"] = 2
        ["recordingGroup", "recordingStartedAt", "recordingEndedAt", "completionReason"]
            .forEach { object.removeValue(forKey: $0) }
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try AVLagReportDocument.decoded(from: data)
        #expect(decoded.recordingGroup == nil)
        #expect(decoded.recordingStartedAt == nil)
        #expect(decoded.recordingEndedAt == nil)
        #expect(decoded.completionReason == nil)
    }
}

/// 模型層只驗證狀態轉移；不建立樣本，因此不會寫入報告檔案。
@Suite("AVLagModel recording binding", .serialized)
struct AVLagModelRecordingBindingTests {
    @Test("綁定群組後結束錄影，完成原因為 recordingEnded")
    @MainActor
    func bindsAndEndsRecording() async {
        let model = AVLagModel.shared
        let group = UUID()
        model.begin(session: "binding-\(UUID().uuidString)")
        model.bindRecording(group: group, startedAt: Date(timeIntervalSince1970: 10))
        #expect(model.recordingGroup == group.uuidString)
        #expect(model.recordingStartedAt == Date(timeIntervalSince1970: 10))

        model.endRecording(group: group, endedAt: Date(timeIntervalSince1970: 20))
        #expect(model.recordingEndedAt == Date(timeIntervalSince1970: 20))
        #expect(model.completionReason == "recordingEnded")

        await model.end()
        #expect(model.completionReason == "recordingEnded")
        #expect(model.endedAt != nil)
    }

    @Test("沒有綁定錄影時停止，完成原因為 captureStopped")
    @MainActor
    func withoutRecordingEndsAsCaptureStopped() async {
        let model = AVLagModel.shared
        model.begin(session: "no-recording-\(UUID().uuidString)")
        await model.end()
        #expect(model.recordingGroup == nil)
        #expect(model.completionReason == "captureStopped")
    }

    @Test("begin 會清掉上一場的錄影綁定")
    @MainActor
    func beginResetsRecordingBinding() async {
        let model = AVLagModel.shared
        model.begin(session: "reset-\(UUID().uuidString)")
        model.bindRecording(group: UUID())
        model.endRecording()
        await model.end()
        model.begin(session: "next-\(UUID().uuidString)")
        #expect(model.recordingGroup == nil)
        #expect(model.recordingStartedAt == nil)
        #expect(model.recordingEndedAt == nil)
        #expect(model.completionReason == nil)
    }
}
