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
    @Published private(set) var recordingGroup: String?
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var recordingEndedAt: Date?
    @Published private(set) var completionReason: String?

    private var segmentIndex = 0
    private var segmentStartedAt: Date?
    private var truncatedBefore = false
    private var estimatedSampleBytes = 0
    private let maxSampleBytes = 2 * 1024 * 1024
    /// 長時間擷取時定期更新進行中 segment，避免 App 在背景被中止後只剩
    /// 進入背景當下的少量樣本。
    private let checkpointInterval: TimeInterval = 60
    private var lastCheckpointAt: Date?
    private var recordedSampleCount = 0
    private var lastCheckpointRecordedCount = 0
    /// 儲存任務必須依序完成；較舊的 checkpoint 不能覆蓋較新的 final 文件。
    private var persistTask: Task<Void, Never>?

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
        recordingGroup = nil
        recordingStartedAt = nil
        recordingEndedAt = nil
        completionReason = nil
        segmentIndex = 0
        segmentStartedAt = Date()
        truncatedBefore = false
        lastCheckpointAt = Date()
        recordedSampleCount = 0
        lastCheckpointRecordedCount = 0
        sendlog(message: "[AVLagStore] begin session=\(session) mode=\(AVLagSettings.mode.rawValue)")
    }

    func record(_ observation: AVLagObservation) {
        guard observation.session == session, endedAt == nil else { return }
        let now = Date()
        if shouldRotateSegment(now: now) {
            rotateSegment(now: now)
        }
        latest = observation
        samples.append(observation)
        recordedSampleCount += 1
        estimatedSampleBytes += estimatedBytes(observation)
        trimLocked()
        checkpointIfNeeded(now: now)
    }

    /// 綁定本場擷取使用的錄影群組；同一場只接受第一次綁定。
    /// - Parameters:
    ///   - group: 錄影分片共用的群組 ID。
    ///   - startedAt: 錄影開始時間，預設為現在。
    func bindRecording(group: UUID, startedAt: Date = Date()) {
        guard isCapturing, recordingGroup == nil else { return }
        recordingGroup = group.uuidString
        recordingStartedAt = startedAt
    }

    /// 標記錄影收尾；只接受目前綁定的群組，重複呼叫不會覆蓋第一次結束時間。
    /// - Parameters:
    ///   - group: 要結束的錄影群組；nil 代表目前群組。
    ///   - endedAt: 錄影結束時間。
    ///   - reason: 完成原因，預設 recordingEnded。
    func endRecording(group: UUID? = nil, endedAt: Date = Date(),
                      reason: String = "recordingEnded") {
        guard recordingGroup != nil else { return }
        if let group, recordingGroup != group.uuidString { return }
        guard recordingEndedAt == nil else { return }
        recordingEndedAt = endedAt
        completionReason = reason
    }

    /// 進行中的檔案最多落後一個 checkpoint 週期；只在有新增樣本時寫入。
    private func checkpointIfNeeded(now: Date) {
        guard AVLagSettings.mode == .recentSessions,
              !samples.isEmpty,
              recordedSampleCount != lastCheckpointRecordedCount,
              now.timeIntervalSince(lastCheckpointAt ?? now) >= checkpointInterval else { return }
        persistInProgress(force: false, now: now)
    }

    /// 背景或定期 checkpoint 保存目前未完成 segment；停止時再覆寫為 complete。
    func persistInProgress() {
        persistInProgress(force: true, now: Date())
    }

    private func persistInProgress(force: Bool, now: Date) {
        guard endedAt == nil,
              AVLagSettings.mode == .recentSessions,
              let session, let startedAt, let segmentStartedAt,
              !samples.isEmpty else { return }
        if !force, recordedSampleCount == lastCheckpointRecordedCount { return }
        persist(
            session: session,
            startedAt: startedAt,
            segmentIndex: segmentIndex,
            segmentStartedAt: segmentStartedAt,
            segmentEndedAt: nil,
            complete: false,
            sessionComplete: false,
            truncatedBefore: truncatedBefore,
            completionReason: completionReason,
            samples: samples)
        lastCheckpointAt = now
        lastCheckpointRecordedCount = recordedSampleCount
    }

    /// 結束本場並等待最終報告寫入完成；避免 App 隨即關閉時只留下 checkpoint。
    /// - Parameters:
    ///   - requestedSession: 只結束指定的 session；nil 代表目前 session。
    ///   - completionReason: 明確指定完成原因；nil 會依錄影狀態推導。
    func end(session requestedSession: String? = nil, completionReason: String? = nil) async {
        if let requestedSession, self.session != requestedSession { return }
        let end = Date()
        endedAt = end
        self.completionReason = completionReason ?? inferredCompletionReason()
        let reason = self.completionReason ?? "unknown"
        guard AVLagSettings.mode == .recentSessions,
              let currentSession = self.session,
              let startedAt, let segmentStartedAt,
              !samples.isEmpty else {
            sendlog(message: "[AVLagStore] final skipped session=\(self.session ?? "none") mode=\(AVLagSettings.mode.rawValue) samples=\(samples.count) reason=\(reason)")
            return
        }
        persist(
            session: currentSession,
            startedAt: startedAt,
            segmentIndex: segmentIndex,
            segmentStartedAt: segmentStartedAt,
            segmentEndedAt: end,
            complete: true,
            sessionComplete: true,
            truncatedBefore: truncatedBefore,
            completionReason: self.completionReason,
            samples: samples)
        // 依序等待 checkpoint 與 final；只有這樣停止後立即可看到 complete=true。
        await persistTask?.value
    }

    /// 沒有錄影時擷取停止；有錄影但未收到結束時間代表取樣中斷。
    private func inferredCompletionReason() -> String {
        if recordingGroup == nil { return "captureStopped" }
        if recordingEndedAt == nil { return "samplingInterrupted" }
        return "recordingEnded"
    }

    /// 只保留目前 session；JSON 報告仍可完整輸出當前保留樣本。
    func trimForMemoryPressure(maxBytes: Int = 512 * 1024) {
        trim(toBytes: maxBytes)
    }

    /// 供人工檢查與回放修復工具讀取的穩定 JSON；只含時間與量測值，不含串流金鑰。
    func reportFileURL() -> URL? {
        guard let session else { return nil }
        return AVLagReportExport.url(text: reportJSON(), session: session, segmentIndex: segmentIndex)
    }

    func reportJSON() -> String {
        guard let session else { return "{\"schema\":1,\"samples\":[]}" }
        let started = startedAt ?? Date()
        let segmentStarted = segmentStartedAt ?? started
        let document = AVLagReportDocument(
            schema: 3,
            session: session,
            startedAt: started,
            endedAt: endedAt,
            segmentIndex: segmentIndex,
            segmentStartedAt: segmentStarted,
            segmentEndedAt: endedAt,
            complete: endedAt != nil,
            sessionComplete: endedAt != nil,
            truncatedBefore: truncatedBefore,
            recordingGroup: recordingGroup,
            recordingStartedAt: recordingStartedAt,
            recordingEndedAt: recordingEndedAt,
            completionReason: endedAt == nil ? nil : completionReason,
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
            completionReason: "segmentRotated",
            samples: samples)
        samples.removeAll(keepingCapacity: true)
        estimatedSampleBytes = 0
        truncatedBefore = false
        segmentIndex += 1
        self.segmentStartedAt = now
        lastCheckpointAt = now
        lastCheckpointRecordedCount = recordedSampleCount
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
                         truncatedBefore: Bool, completionReason: String?,
                         samples: [AVLagObservation]) {
        let document = AVLagReportDocument(
            schema: 3,
            session: session,
            startedAt: startedAt,
            endedAt: segmentEndedAt,
            segmentIndex: segmentIndex,
            segmentStartedAt: segmentStartedAt,
            segmentEndedAt: segmentEndedAt,
            complete: complete,
            sessionComplete: sessionComplete,
            truncatedBefore: truncatedBefore,
            recordingGroup: recordingGroup,
            recordingStartedAt: recordingStartedAt,
            recordingEndedAt: recordingEndedAt,
            completionReason: completionReason,
            sampleCount: samples.count,
            samples: samples)
        // 依呼叫順序串接，避免背景 checkpoint 晚於 final save 完成而蓋掉較新的內容。
        let previous = persistTask
        persistTask = Task {
            _ = await previous?.value
            do {
                try await AVLagReportStore.shared.save(document)
                if complete {
                    sendlog(message: "[AVLagStore] saved session=\(session) segment=\(segmentIndex) samples=\(samples.count) complete=true")
                }
            } catch {
                sendlog(message: "[AVLagStore] save failed session=\(session) segment=\(segmentIndex) error=\(error)")
            }
        }
    }

    /// 粗估可變字串與固定欄位；目的是套上限，不用來宣稱精確 heap 用量。
    private func estimatedBytes(_ observation: AVLagObservation) -> Int {
        256
            + observation.session.utf8.count
            + (observation.videoQueue?.utf8.count ?? 0)
    }
}
