import Foundation

/// 單次推流的可觀測狀態。格式來自編碼器、封包來自 RTMP 統計，不能用設定值代替成功證據。
struct CaptureStreamTelemetry: Equatable, Sendable {
    /// 本機擷取摘要每五秒更新；與 RTMP 封包統計分開，避免誤認已送達伺服器。
    var pipelineSampledAt: Date?
    var sourceQueues: String?
    var mixerAudio: String?
    var stage = "idle"
    var failed = false
    var encoderFormat: String?
    var audioPackets: Int?
    var sampledAt: Date?
    var targetBitrate = 0
    var stageStartedAt = Date()
    private var lastEventAt = Date.distantPast

    /// 只解析既有、低頻的結構化摘要；未知訊息不更動狀態，避免一般日誌覆蓋連線進度。
    mutating func consume(message: String, detail: String?, now: Date = Date()) {
        guard !failed, now >= lastEventAt else { return }
        lastEventAt = now
        let previousStage = stage
        if message.hasPrefix("TCP connecting") { stage = "tcp" }
        else if message.hasPrefix("TCP connected") { stage = "handshake" }
        else if message.hasPrefix("S0S1 received") { stage = "handshakeReply" }
        else if message.hasPrefix("State:"), message.hasSuffix("=> handshakeDone") { stage = "connect" }
        else if message.hasPrefix("Connect success") { stage = "publish" }
        if message.hasPrefix("Reconnect"), !message.hasPrefix("Reconnect disabled") { stage = "reconnect" }
        if stage != previousStage {
            stageStartedAt = now
            if stage == "tcp" || stage == "reconnect" { audioPackets = nil; sampledAt = nil }
        }
        if message.hasPrefix("audio: format="), let output = message.range(of: "output=") {
            let text = String(message[output.upperBound...])
            // AVAudioFormat 的診斷描述包含位址；只擷取聲道、取樣率與已知 codec 名稱。
            if let range = text.range(of: #"\d+ ch,\s*[\d.]+ Hz"#, options: .regularExpression) {
                let codec = message.components(separatedBy: " input=").first?.replacingOccurrences(of: "audio: format=", with: "") ?? ""
                encoderFormat = codec + " · " + String(text[range])
            }
        }
        if message == "publish throughput", let detail,
           let range = detail.range(of: #"\baudioFrames=\d+"#, options: .regularExpression),
           let value = Int(detail[range].split(separator: "=").last ?? "") {
            stage = "published"
            audioPackets = value
            sampledAt = now
        }
    }

    /// 統計約十秒更新；逾二十秒不沿用舊成功狀態。封包產出並非伺服器播放確認。
    func audioState(at now: Date = Date()) -> String {
        guard let sampledAt, let audioPackets else {
            return now.timeIntervalSince(stageStartedAt) > 20 ? "stale" : "waiting"
        }
        if now.timeIntervalSince(sampledAt) > 20 { return "stale" }
        return audioPackets > 0 ? "packets" : "missing"
    }
}
