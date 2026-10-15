import Foundation
import Testing
@testable import liveAPP

/// 解讀只使用原始報告提供的值，缺漏或未知單位不得生成誤導比例。
struct MetricReportAnalysisTests {
    @Test func diskReportDoesNotInventMemory() throws {
        let text = #"{"schemaVersion":1,"report":{"diskSpaceUsageMetrics":{"totalDiskSpaceCapacity":"256000000 kB","totalDiskSpaceUsedSize":"244752658 kB","totalDataFileSize":"117404 kB"}}}"#
        let result = try MetricReportAnalysis.parse(text)
        let fraction = try #require(result.deviceStorageFraction)
        #expect(abs(fraction - 0.9560650703125) < 0.000001)
        #expect(result.missing.contains("記憶體統計"))
        #expect(result.sections.count == 1)
        #expect(result.sections[0].fields.contains { $0.value == "117404 kB" })
    }

    @Test func unknownUnitsDoNotProduceChart() throws {
        let result = try MetricReportAnalysis.parse(#"{"schemaVersion":1,"report":{"diskSpaceUsageMetrics":{"totalDiskSpaceCapacity":"100 mystery","totalDiskSpaceUsedSize":"20 mystery"}}}"#)
        #expect(result.deviceStorageFraction == nil)
    }

    @Test func diagnosticsShowEventCounts() throws {
        let result = try MetricReportAnalysis.parse(#"{"schemaVersion":1,"report":{"diagnosticMetrics":{"crashDiagnostics":[{},{}]}}}"#)
        #expect(result.sections[0].fields[0].value.hasPrefix("2 筆"))
        #expect(!result.missing.contains("異常診斷"))
    }
}
