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

    private var segmentIndex = 0
    private var segmentStartedAt: Date?
    private var truncatedBefore = false
    private var estimatedSampleBytes = 0
    private let maxSampleBytes = 2 * 1024 * 1024

    private var maxSamples: Int {
        max(1, AVLagSettings.maxSamplesPerSegment)
    }

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
        segmentIndex = 0
        segmentStartedAt = Date()
        truncatedBefore = false
    }

    func record(_ observation: AVLagObservation) {
        guard observation.session == session, endedAt == nil else { return }
        let now = Date()
        if shouldRotateSegment(now: now) {
            rotateSegment(now: now)
        }
        latest = observation
        samples.append(observation)
        estimatedSampleBytes += estimatedBytes(observation)
        trimLocked()
    }

    /// 背景時保存目前未完成 segment；畫面恢復後若繼續累積，停止時會覆寫為 complete。
    func persistInProgress() {
        guard endedAt == nil,
              AVLagSettings.mode == .recentSessions,
              let session, let startedAt, let segmentStartedAt,
              !samples.isEmpty else { return }
        persist(
            session: session,
            startedAt: startedAt,
            segmentIndex: segmentIndex,
            segmentStartedAt: segmentStartedAt,
            segmentEndedAt: nil,
            complete: false,
            sessionComplete: false,
            truncatedBefore: truncatedBefore,
            samples: samples)
    }

    func end(session: String? = nil) {
        if let session, self.session != session { return }
        let end = Date()
        endedAt = end
        guard AVLagSettings.mode == .recentSessions,
              let session, let startedAt, let segmentStartedAt,
              !samples.isEmpty else { return }
        persist(
            session: session,
            startedAt: startedAt,
            segmentIndex: segmentIndex,
            segmentStartedAt: segmentStartedAt,
            segmentEndedAt: end,
            complete: true,
            sessionComplete: true,
            truncatedBefore: truncatedBefore,
            samples: samples)
    }

    /// 只保留目前 session；JSON 報告仍可完整輸出當前保留樣本。
    func trimForMemoryPressure(maxBytes: Int = 512 * 1024) {
        trim(toBytes: maxBytes)
    }

    /// 供人工檢查與回放修復工具讀取的穩定 JSON；只含時間與量測值，不含串流金鑰。
    func reportJSON() -> String {
        guard let session else { return "{\"schema\":1,\"samples\":[]}" }
        let started = startedAt ?? Date()
        let segmentStarted = segmentStartedAt ?? started
        let document = AVLagReportDocument(
            schema: 1,
            session: session,
            startedAt: started,
            endedAt: endedAt,
            segmentIndex: segmentIndex,
            segmentStartedAt: segmentStarted,
            segmentEndedAt: endedAt,
            complete: endedAt != nil,
            sessionComplete: endedAt != nil,
            truncatedBefore: truncatedBefore,
            sampleCount: samples.count,
            samples: samples)
        return document.jsonText
    }

    private func shouldRotateSegment(now: Date) -> Bool {
        guard AVLagSettings.mode == .recentSessions,
              AVLagSettings.longSessionSegments,
              let segmentStartedAt,
              !samples.isEmpty else { return false }
        return now.timeIntervalSince(segmentStartedAt) >= AVLagSettings.segmentDuration
            || samples.count >= maxSamples
            || estimatedSampleBytes >= maxSampleBytes
    }

    private func rotateSegment(now: Date) {
        guard let session, let startedAt, let segmentStartedAt,
              !samples.isEmpty else { return }
        persist(
            session: session,
            startedAt: startedAt,
            segmentIndex: segmentIndex,
            segmentStartedAt: segmentStartedAt,
            segmentEndedAt: now,
            complete: true,
            sessionComplete: false,
            truncatedBefore: truncatedBefore,
            samples: samples)
        samples.removeAll(keepingCapacity: true)
        estimatedSampleBytes = 0
        truncatedBefore = false
        segmentIndex += 1
        self.segmentStartedAt = now
    }

    private func trimLocked() {
        trim(toBytes: maxSampleBytes)
    }

    private func trim(toBytes byteLimit: Int) {
        var removed = false
        while samples.count > maxSamples || estimatedSampleBytes > byteLimit {
            guard !samples.isEmpty else { estimatedSampleBytes = 0; break }
            let value = samples.removeFirst()
            estimatedSampleBytes = max(0, estimatedSampleBytes - estimatedBytes(value))
            removed = true
        }
        if removed { truncatedBefore = true }
    }

    private func persist(session: String, startedAt: Date, segmentIndex: Int,
                         segmentStartedAt: Date, segmentEndedAt: Date?,
                         complete: Bool, sessionComplete: Bool,
                         truncatedBefore: Bool, samples: [AVLagObservation]) {
        let document = AVLagReportDocument(
            schema: 1,
            session: session,
            startedAt: startedAt,
            endedAt: segmentEndedAt,
            segmentIndex: segmentIndex,
            segmentStartedAt: segmentStartedAt,
            segmentEndedAt: segmentEndedAt,
            complete: complete,
            sessionComplete: sessionComplete,
            truncatedBefore: truncatedBefore,
            sampleCount: samples.count,
            samples: samples)
        Task {
            do { try await AVLagReportStore.shared.save(document) }
            catch { sendlog(message: "[AVLagStore] save failed session=\(session) segment=\(segmentIndex) error=\(error)") }
        }
    }

    /// 粗估可變字串與固定欄位；目的是套上限，不用來宣稱精確 heap 用量。
    private func estimatedBytes(_ observation: AVLagObservation) -> Int {
        256
            + observation.session.utf8.count
            + (observation.videoQueue?.utf8.count ?? 0)
    }
}
