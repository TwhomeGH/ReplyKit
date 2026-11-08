import Foundation

/// 單一 AV Lag segment 的可攜文件；schema 與即時報告共用，回放工具只需讀 samples。
struct AVLagReportDocument: Codable, Sendable {
    var schema = 1
    var session: String
    var startedAt: Date
    var endedAt: Date?
    var segmentIndex: Int
    var segmentStartedAt: Date
    var segmentEndedAt: Date?
    var complete: Bool
    var sessionComplete: Bool
    var truncatedBefore: Bool
    var sampleCount: Int
    var samples: [AVLagObservation]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    var jsonText: String {
        (try? encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

struct AVLagSegmentSummary: Codable, Identifiable, Sendable {
    var index: Int
    var startedAt: Date
    var endedAt: Date?
    var sampleCount: Int
    var bytes: Int
    var complete: Bool
    var sessionComplete: Bool

    var id: Int { index }
}

struct AVLagSessionSummary: Codable, Identifiable, Sendable {
    var id: String
    var startedAt: Date
    var endedAt: Date?
    var segments: [AVLagSegmentSummary]
    var sampleCount: Int
    var bytes: Int
    var complete: Bool
    var truncatedBefore: Bool
}

private struct AVLagReportIndex: Codable {
    var schema = 1
    var sessions: [AVLagSessionSummary] = []
}

/// 只在停止、分段或背景時寫入；以 session 為保留單位，子 segment 一起刪除。
actor AVLagReportStore {
    static let shared = AVLagReportStore()
    static let didChangeNotification = Notification.Name("AVLagReportStoreDidChange")

    private let root: URL
    private let indexURL: URL
    private let maxSessions = AVLagSettings.recentLimit
    private let maxTotalBytes = AVLagSettings.maxTotalBytes

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        root = base.appendingPathComponent("AVLagReports", isDirectory: true)
        indexURL = root.appendingPathComponent("index.json")
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func fileURL(session: String, segment: Int) -> URL {
        root.appendingPathComponent("\(session)-\(segment).json")
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func readIndex() -> AVLagReportIndex {
        guard let data = try? Data(contentsOf: indexURL),
              let value = try? decoder().decode(AVLagReportIndex.self, from: data) else {
            return AVLagReportIndex()
        }
        return value
    }

    private func writeIndex(_ index: AVLagReportIndex) throws {
        try ensureDirectory()
        try encoder().encode(index).write(to: indexURL, options: .atomic)
    }

    private func notifyChanged() {
        Task { @MainActor in
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    func summaries() -> [AVLagSessionSummary] {
        readIndex().sessions.sorted {
            ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt)
        }
    }

    func save(_ document: AVLagReportDocument) throws {
        try ensureDirectory()
        let data = try document.encoded()
        try data.write(to: fileURL(session: document.session, segment: document.segmentIndex),
                       options: .atomic)

        var index = readIndex()
        let segment = AVLagSegmentSummary(
            index: document.segmentIndex,
            startedAt: document.segmentStartedAt,
            endedAt: document.segmentEndedAt,
            sampleCount: document.sampleCount,
            bytes: data.count,
            complete: document.complete,
            sessionComplete: document.sessionComplete)

        if let position = index.sessions.firstIndex(where: { $0.id == document.session }) {
            var session = index.sessions[position]
            session.startedAt = min(session.startedAt, document.startedAt)
            session.segments.removeAll { $0.index == document.segmentIndex }
            session.segments.append(segment)
            session.segments.sort { $0.index < $1.index }
            session.sampleCount = session.segments.reduce(0) { $0 + $1.sampleCount }
            session.bytes = session.segments.reduce(0) { $0 + $1.bytes }
            session.complete = session.segments.contains(where: \.sessionComplete)
            session.truncatedBefore = session.truncatedBefore || document.truncatedBefore
            session.endedAt = session.complete
                ? session.segments.compactMap(\.endedAt).max()
                : nil
            index.sessions[position] = session
        } else {
            let session = AVLagSessionSummary(
                id: document.session,
                startedAt: document.startedAt,
                endedAt: document.complete ? document.segmentEndedAt : nil,
                segments: [segment],
                sampleCount: segment.sampleCount,
                bytes: segment.bytes,
                complete: document.sessionComplete,
                truncatedBefore: document.truncatedBefore)
            index.sessions.append(session)
        }

        prune(&index)
        try writeIndex(index)
        notifyChanged()
    }

    func documents(for sessionID: String) -> [AVLagReportDocument] {
        guard let summary = readIndex().sessions.first(where: { $0.id == sessionID }) else {
            return []
        }
        return summary.segments.compactMap { segment in
            guard let data = try? Data(contentsOf: fileURL(session: sessionID, segment: segment.index))
            else { return nil }
            return try? decoder().decode(AVLagReportDocument.self, from: data)
        }.sorted { $0.segmentIndex < $1.segmentIndex }
    }

    func delete(sessionID: String) {
        guard let summary = readIndex().sessions.first(where: { $0.id == sessionID }) else { return }
        for segment in summary.segments {
            try? FileManager.default.removeItem(at: fileURL(session: sessionID, segment: segment.index))
        }
        var index = readIndex()
        index.sessions.removeAll { $0.id == sessionID }
        try? writeIndex(index)
        notifyChanged()
    }

    func clear() {
        try? FileManager.default.removeItem(at: root)
        try? ensureDirectory()
        try? writeIndex(AVLagReportIndex())
        notifyChanged()
    }

    private func prune(_ index: inout AVLagReportIndex) {
        index.sessions.sort {
            ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt)
        }
        while index.sessions.count > maxSessions {
            removeOldest(&index)
        }
        while totalBytes(index.sessions) > maxTotalBytes, index.sessions.count > 1 {
            removeOldest(&index)
        }
    }

    private func totalBytes(_ sessions: [AVLagSessionSummary]) -> Int {
        sessions.reduce(0) { $0 + $1.bytes }
    }

    private func removeOldest(_ index: inout AVLagReportIndex) {
        guard let oldest = index.sessions.popLast() else { return }
        for segment in oldest.segments {
            try? FileManager.default.removeItem(at: fileURL(session: oldest.id, segment: segment.index))
        }
    }
}
