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
    /// 系統完成錄影時的原始檔大小；舊紀錄無此資訊。
    var originalBytes: Int64?
    /// 同一場可控錄製的群組與片段序號，舊紀錄為 nil。
    var segmentGroup: UUID?
    var segmentNumber: Int?
    /// 合併產物所屬群組；與原始片段分開保存，不參與再次合併。
    var mergedFromGroup: UUID?
    /// 轉碼暫存檔大小；完成前不可當作可播放產物。
    var compressedBytes: Int64?
    /// true 才表示壓縮產物通過驗證並取代原檔。
    var compressionCompleted: Bool?
    /// 統一前端容量標示；失敗及未完成不顯示節省量。
    var sizeSummary: String {
        func mb(_ value: Int64) -> String { String(format: "%.1f MB", Double(value) / 1_000_000) }
        guard let originalBytes else { return "檔案大小：" + mb(bytes) }
        let before = "壓縮前：" + mb(originalBytes)
        if compressionCompleted == true, let compressedBytes {
            let saved = max(0, originalBytes - compressedBytes)
            let percent = originalBytes > 0 ? Double(saved) / Double(originalBytes) * 100 : 0
            return before + " · 壓縮後：" + mb(compressedBytes) + " · 節省：" + mb(saved) + String(format: "（%.1f%%）", percent)
        }
        if let compressedBytes, !phase.isTerminal {
            return before + " · 壓縮輸出（未完成）：" + mb(compressedBytes)
        }
        return before + (phase.isTerminal ? " · 壓縮未套用" : " · 壓縮後：等待處理")
    }
    /// 只有完成回呼可以傳入 ready；終態不接受晚到回呼覆寫。
    @discardableResult mutating func transition(to next: RecordingPhase) -> Bool {
        guard !phase.isTerminal else { return false }
        if next == .recording && phase != .preparing { return false }
        if next == .preparing { return false }
        phase = next; return true
    }
    /// 呼叫端驗證檔案後使用；不宣稱已恢復事故前所有資料。
    mutating func markRecovered(duration: Double, bytes: Int64) {
        guard phase == .interrupted else { return }
        phase = .ready; self.duration = duration; self.bytes = bytes
        message = "已驗證現存檔案可播放；中斷前最後資料可能遺失。"
    }
    mutating func recoverAfterRelaunch() {
        if !phase.isTerminal { phase = .interrupted; message = "上次錄製中斷，未收到完成確認。" }
    }
}
