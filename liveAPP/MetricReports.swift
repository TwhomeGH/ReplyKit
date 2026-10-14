#if os(iOS)
import Foundation
import MetricKit
import Combine
import CryptoKit

/// 報告列表只保留摘要；完整 JSON 按需讀取，不把所有堆疊長期放在記憶體。
struct MetricReportEntry: Identifiable, Sendable {
    /// 原始報告雜湊形成的 JSON 檔名，用於穩定識別與去重。
    let id: String
    /// 本機報告路徑；超過保留限制後可能已清除。
    let url: URL
    /// App 收到報告的時間，不是異常實際發生時間。
    let received: Date
    /// 顯示用報告分類，例如效能統計或異常診斷。
    let kind: String
    /// 原始報告的起訖時間文字；缺漏以未知顯示。
    let period: String
    /// 已知統計欄位的摘要，不代表完整健康判定。
    let summary: String

    /// 只摘要已存在的欄位；缺少值不推定為零或正常。
    static func summary(for report: [String: Any]) -> String {
        var lines: [String] = []
        if let diagnostics = report["diagnosticMetrics"] as? [String: Any] {
            let labels = ["crashDiagnostics": "崩潰", "hangDiagnostics": "卡頓",
                          "cpuExceptionDiagnostics": "CPU 異常", "diskWriteExceptionDiagnostics": "磁碟寫入異常"]
            for key in diagnostics.keys.sorted() {
                if let values = diagnostics[key] as? [Any] { lines.append("\(labels[key] ?? key)：\(values.count) 筆") }
            }
        }
        for (group, field, label) in [("cpuMetrics", "cumulativeCPUTime", "CPU 累計時間"),
                                     ("memoryMetrics", "peakMemoryUsage", "記憶體峰值"),
                                     ("diskIOMetrics", "cumulativeLogicalWrites", "邏輯寫入量")] {
            if let values = report[group] as? [String: Any], let value = values[field] as? String {
                lines.append(label + "：" + value)
            }
        }
        if lines.isEmpty {
            lines = report.keys.filter { $0.lowercased().contains("metric") || $0.lowercased().contains("diagnostic") }.sorted()
        }
        return lines.isEmpty ? "詳細內容請查看 JSON" : lines.joined(separator: "、")
    }
}

/// 主 App 的唯一 MetricKit 訂閱者。檔案 I/O 由 queue 串行管理；
/// started 與 Published 狀態只在主執行緒存取。回呼只傳遞 Data 到 queue。
/// 使用相容舊 iOS 的 MX API；未將主 App 報告當作 ReplayKit 擴展報告。
final class MetricReports: NSObject, ObservableObject, MXMetricManagerSubscriber, @unchecked Sendable {
    /// 跨視窗共用的唯一訂閱者，隨 App 程序存活。
    static let shared = MetricReports()
    @Published private(set) var reports: [MetricReportEntry] = []
    @Published private(set) var errorMessage: String?
    @MainActor private var started = false
    /// 序列化保存、讀取與容量清理，避免檔案操作互相競爭。
    private let queue = DispatchQueue(label: "liveAPP.metricReports", qos: .utility)
    private let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MetricReports", isDirectory: true)
    private override init() { super.init() }

    /// 由 App 啟動入口呼叫，重複呼叫不會重複訂閱；生命週期不依附視窗。
    @MainActor func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
        refresh()
    }
    /// 將效能報告轉為 JSON 後排入保存佇列。
    /// - Parameter payloads: 系統此次提供的統計報告，不保證即時到達。
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { save(payload.jsonRepresentation(), kind: "效能統計") }
    }
    /// 將異常診斷轉為 JSON 後排入保存佇列。
    /// - Parameter payloads: 系統此次提供的診斷，未收到不表示沒有異常。
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { save(payload.jsonRepresentation(), kind: "異常診斷") }
    }
    /// 原始報告雜湊用於去重；接收時版本與原始報告版本分開保存。
    private func save(_ data: Data, kind: String) {
        queue.async {
            do {
                guard data.count <= 5_000_000 else {
                    throw NSError(domain: "MetricReports", code: 1, userInfo: [NSLocalizedDescriptionKey: "單份報告超過 5 MB，未保存。"])
                }
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let url = self.directory.appendingPathComponent(digest + ".json")
                if !FileManager.default.fileExists(atPath: url.path) {
                    let report = try JSONSerialization.jsonObject(with: data)
                    let envelope: [String: Any] = ["schemaVersion": 1, "kind": kind,
                        "receivedAt": ISO8601DateFormatter().string(from: Date()),
                        "buildInfoAtReceipt": BuildInformation.current.report, "report": report]
                    let encoded = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
                    guard encoded.count <= 5_000_000 else {
                        throw NSError(domain: "MetricReports", code: 2, userInfo: [NSLocalizedDescriptionKey: "報告封裝超過 5 MB，未保存。"])
                    }
                    try encoded.write(to: url, options: .atomic)
                }
                try self.reloadLocked()
            } catch { self.publishError(error) }
        }
    }
    /// 重新讀取已收到的報告，無法要求系統立即產生新報告。
    func refresh() {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                try self.reloadLocked()
            } catch { self.publishError(error) }
        }
    }
    private func publishError(_ error: Error) {
        let message = error.localizedDescription
        DispatchQueue.main.async { self.errorMessage = message }
    }
    /// 僅在檔案佇列呼叫，按修改時間優先保留較新的 JSON。
    /// 最多列出 30 份可讀報告，檔案總量限制 20 MB、單份限制 5 MB。
    /// 解析失敗的檔案仍計入容量，但不計入可讀份數；超限檔案會移除。
    /// - Throws: 目錄列舉、屬性讀取或移除檔案失敗。
    private func reloadLocked() throws {
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]).filter { $0.pathExtension == "json" }
        let sorted = try urls.map { ($0, try $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])) }
            .sorted { ($0.1.contentModificationDate ?? .distantPast) > ($1.1.contentModificationDate ?? .distantPast) }
        var used = 0
        var entries: [MetricReportEntry] = []
        var unreadable = 0
        for (url, values) in sorted {
            let bytes = values.fileSize ?? 0
            guard entries.count < 30, bytes <= 5_000_000, used + bytes <= 20_000_000 else {
                try FileManager.default.removeItem(at: url)
                continue
            }
            used += bytes
            guard let data = try? Data(contentsOf: url),
                  let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  envelope["schemaVersion"] as? Int == 1,
                  let report = envelope["report"] as? [String: Any] else { unreadable += 1; continue }
            let received = (envelope["receivedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast
            let begin = report["timeStampBegin"] as? String ?? "未知"
            let end = report["timeStampEnd"] as? String ?? "未知"
            entries.append(MetricReportEntry(id: url.lastPathComponent, url: url, received: received,
                kind: envelope["kind"] as? String ?? "系統報告", period: "\(begin) → \(end)",
                summary: MetricReportEntry.summary(for: report)))
        }
        let snapshot = entries
        publishSnapshot(snapshot, warning: unreadable > 0 ? "有 \(unreadable) 份報告無法讀取，檔案仍保留。" : nil)
    }
    /// 與檔案 queue 分開發佈，避免 SwiftUI 從背景執行緒收到更新。
    private func publishSnapshot(_ entries: [MetricReportEntry], warning: String?) {
        DispatchQueue.main.async { self.reports = entries; self.errorMessage = warning }
    }
    /// 在檔案佇列按需讀取完整報告，包含接收時的建置資訊封裝。
    /// - Parameter entry: 要讀取的列表紀錄。
    /// - Returns: UTF-8 JSON 文字。
    /// - Throws: 檔案已清除、讀取失敗或文字編碼錯誤。
    func contents(of entry: MetricReportEntry) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try String(contentsOf: entry.url, encoding: .utf8)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

#endif
