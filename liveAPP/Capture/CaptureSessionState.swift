import Foundation

enum CaptureBackend: String, CaseIterable, Identifiable {
    case replayKit, screenCaptureKit
    var id: String { rawValue }
    var title: String { self == .replayKit ? "ReplayKit" : "ScreenCaptureKit（測試中）" }
}

enum CapturePhase: String {
    case idle, selecting, starting, streaming, stopping
    var title: String {
        switch self {
        case .idle: return "尚未開始"
        case .selecting: return "請選擇要分享的畫面"
        case .starting: return "正在啟動擷取"
        case .streaming: return "擷取中"
        case .stopping: return "正在停止擷取"
        }
    }
}

/// 每次工作使用新識別；晚到的啟動結果不得把已停止的工作設為直播中。
struct CaptureSessionState {
    private(set) var id: UUID?
    private(set) var phase: CapturePhase = .idle
    mutating func begin() -> UUID? {
        guard phase == .idle else { return nil }
        let token = UUID(); id = token; phase = .selecting; return token
    }
    @discardableResult mutating func transition(_ phase: CapturePhase, for token: UUID) -> Bool {
        guard id == token, self.phase != .stopping else { return false }
        let valid = (self.phase == .selecting && phase == .starting) ||
            (self.phase == .starting && phase == .streaming)
        guard valid else { return false }; self.phase = phase; return true
    }
    mutating func stopping() { if id != nil { phase = .stopping } }
    mutating func finish(_ token: UUID) { if id == token { id = nil; phase = .idle } }
}

/// 輸出目的與擷取來源分開；只錄製不需要任何網路設定。
enum CaptureWorkMode: String, CaseIterable, Identifiable {
    case stream, record, streamAndRecord
    var id: String { rawValue }
    var wantsStreaming: Bool { self != .record }
    var wantsRecording: Bool { self != .stream }
    var title: String {
        switch self {
        case .stream: return "只推流"
        case .record: return "只錄製"
        case .streamAndRecord: return "推流並錄製"
        }
    }
    var startTitle: String {
        switch self {
        case .stream: return "開始直播"
        case .record: return "開始錄製"
        case .streamAndRecord: return "開始直播並錄製"
        }
    }
    func accepts(endpoint: String, key: String) -> Bool {
        guard wantsStreaming else { return true }
        guard let url = URL(string: endpoint), ["rtmp", "rtmps"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum RecordingPhase: String, Codable {
    case preparing, recording, finishing, ready, failed, interrupted
    var isTerminal: Bool { self == .ready || self == .failed || self == .interrupted }
    var title: String {
        switch self {
        case .preparing: return "準備錄製"
        case .recording: return "錄製中"
        case .finishing: return "正在完成檔案"
        case .ready: return "錄製完成"
        case .failed: return "錄製失敗"
        case .interrupted: return "未確認完成"
        }
    }
}

struct LocalRecording: Identifiable, Codable {
    let id: UUID
    let created: Date
    private(set) var phase: RecordingPhase = .preparing
    var duration: Double = 0
    var bytes: Int64 = 0
    var message: String?
    /// 只有完成回呼可以傳入 ready；終態不接受晚到回呼覆寫。
    @discardableResult mutating func transition(to next: RecordingPhase) -> Bool {
        guard !phase.isTerminal else { return false }
        if next == .recording && phase != .preparing { return false }
        if next == .preparing { return false }
        phase = next; return true
    }
    mutating func recoverAfterRelaunch() {
        if !phase.isTerminal { phase = .interrupted; message = "上次錄製中斷，未收到完成確認。" }
    }
}
