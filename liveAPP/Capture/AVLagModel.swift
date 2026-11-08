import Combine
import Foundation

/// 目前擷取 session 的 A/V 內容延遲序列；同時供裝置頁即時查看與回放校正匯出。
@MainActor
final class AVLagModel: ObservableObject {
    static let shared = AVLagModel()

    @Published private(set) var latest: AVLagObservation?
    @Published private(set) var samples: [AVLagObservation] = []
    @Published private(set) var session: String?
    @Published private(set) var startedAt: Date?
    @Published private(set) var endedAt: Date?

    private let maxSamples = 2_880
    private let maxSampleBytes = 2 * 1024 * 1024
    private var estimatedSampleBytes = 0

    private init() {}

    struct Stats: Sendable {
        let count: Int
        let bytes: Int
    }

    var stats: Stats {
        Stats(count: samples.count, bytes: estimatedSampleBytes)
    }

    var isCapturing: Bool {
        session != nil && endedAt == nil
    }

    /// 每個擷取 session 重新建立序列；不把上一個 session 的資料混入本輪報告。
    func begin(session: String) {
        self.session = session
        startedAt = Date()
        endedAt = nil
        latest = nil
        samples.removeAll()
        estimatedSampleBytes = 0
    }

    func record(_ observation: AVLagObservation) {
        guard observation.session == session else { return }
        latest = observation
        samples.append(observation)
        estimatedSampleBytes += estimatedBytes(observation)
        trimLocked()
    }

    /// 只保留目前 session；JSON 報告仍可完整輸出當前保留樣本。
    func trimForMemoryPressure(maxBytes: Int = 512 * 1024) {
        while estimatedSampleBytes > maxBytes, !samples.isEmpty {
            let removed = samples.removeFirst()
            estimatedSampleBytes = max(0, estimatedSampleBytes - estimatedBytes(removed))
        }
    }

    private func trimLocked() {
        while samples.count > maxSamples || estimatedSampleBytes > maxSampleBytes {
            guard !samples.isEmpty else { estimatedSampleBytes = 0; return }
            let removed = samples.removeFirst()
            estimatedSampleBytes = max(0, estimatedSampleBytes - estimatedBytes(removed))
        }
    }

    /// 粗估可變字串與固定欄位；目的是套上限，不用來宣稱精確 heap 用量。
    private func estimatedBytes(_ observation: AVLagObservation) -> Int {
        256
            + observation.session.utf8.count
            + (observation.videoQueue?.utf8.count ?? 0)
    }

    func end(session: String? = nil) {
        if let session, self.session != session { return }
        endedAt = Date()
    }

    /// 供人工檢查與回放修復工具讀取的穩定 JSON；只含時間與量測值，不含串流金鑰。
    func reportJSON() -> String {
        struct Report: Codable {
            let schema: Int
            let session: String?
            let startedAt: Date?
            let endedAt: Date?
            let sampleCount: Int
            let samples: [AVLagObservation]
        }

        let report = Report(
            schema: 1,
            session: session,
            startedAt: startedAt,
            endedAt: endedAt,
            sampleCount: samples.count,
            samples: samples)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"schema\":1,\"samples\":[]}"
        }
        return text
    }
}
