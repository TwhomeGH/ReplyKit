import SwiftUI
import Charts
import HaishinKit
import RTMPHaishinKit

/// 每個來源保存最新快照與最多 60 筆速率；較舊取樣不可覆蓋新資料。
@MainActor final class StreamDiagnosticsModel: ObservableObject {
    static let shared = StreamDiagnosticsModel()
    @Published private(set) var snapshots: [String: StreamDiagnosticsSnapshot] = [:]
    @Published private(set) var receivedAt: [String: Date] = [:]
    @Published private(set) var history: [String: [MixerRatePoint]] = [:]

    func record(_ snapshot: StreamDiagnosticsSnapshot, now: Date = Date()) {
        guard snapshot.schemaVersion == 1,
              ["ReplayKit", "ScreenCaptureKit"].contains(snapshot.source),
              snapshot.sampledAt <= now.addingTimeInterval(5),
              snapshots[snapshot.source].map({ $0.sampledAt < snapshot.sampledAt }) ?? true else { return }
        let previous = snapshots[snapshot.source]
        var points = history[snapshot.source] ?? []
        if previous?.session != snapshot.session { points = [] }
        // 長間隔不跨過缺測區連線；重新建立基準後才畫速率。
        let elapsed = snapshot.sampledUptime.flatMap { current in
            previous?.sampledUptime.map { current - $0 }
        } ?? 0
        if elapsed <= 0 || elapsed > 15 { points = [] }
        let point = MixerRatePoint(snapshot: snapshot,
                                   previous: previous?.session == snapshot.session ? previous : nil,
                                   elapsed: elapsed)
        points.append(point)
        history[snapshot.source] = Array(points.suffix(60))
        snapshots[snapshot.source] = snapshot
        receivedAt[snapshot.source] = now
    }
}

/// 同一 session 的 Mixer 輸出差分；取樣率和每秒交付 sample frames 是不同量。
struct MixerRatePoint: Identifiable {
    let id: Date
    let videoFPS: Double?
    let audioBuffersPerSecond: Double?
    let audioFramesPerSecond: Double?

    init(snapshot: StreamDiagnosticsSnapshot, previous: StreamDiagnosticsSnapshot?, elapsed: Double) {
        id = snapshot.sampledAt
        videoFPS = DiagnosticCounterRate.value(current: snapshot.mixerVideoFrames,
            previous: previous?.mixerVideoFrames, elapsed: elapsed)
        audioBuffersPerSecond = DiagnosticCounterRate.value(current: snapshot.mixerAudioBuffers,
            previous: previous?.mixerAudioBuffers, elapsed: elapsed)
        audioFramesPerSecond = DiagnosticCounterRate.value(current: snapshot.mixerAudioFrames,
            previous: previous?.mixerAudioFrames, elapsed: elapsed)
    }
}

/// 兩種來源共用的 Mixer 輸出圖表；不將輸出 FPS 當作來源擷取 FPS 或網路完成率。
struct MixerPipelineCard: View {
    let audio: Bool
    let now: Date
    @ObservedObject private var model = StreamDiagnosticsModel.shared

    var body: some View {
        SettingsDashboardCard(audio ? "Audio Pipeline · 混音輸出" : "Video Pipeline · 混合輸出") {
            if model.snapshots.isEmpty {
                Text("等待擷取管線回報；ReplayKit 需連上主 App Socket。")
                    .foregroundStyle(.secondary)
            }
            ForEach(["ReplayKit", "ScreenCaptureKit"], id: \.self) { source in
                if let snapshot = model.snapshots[source] {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(source).font(.headline)
                        if source == "ScreenCaptureKit" {
                            CapturePipelineStatusView(sampledAt: snapshot.sampledAt, now: now)
                        } else {
                            Text(now.timeIntervalSince(snapshot.sampledAt) > 15
                                 ? "未收到近期回報 · 保留最後資料" : "每五秒更新")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text((audio ? snapshot.mixerAudio : snapshot.mixerVideo) ?? "尚未提供格式")
                            .font(.caption).textSelection(.enabled)
                            // 雙欄卡片仍須完整呈現色彩與音訊欄位，讓高度隨換行增加。
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        let points = model.history[source] ?? []
                        let latest = points.last
                        Text(rate(audio ? latest?.audioBuffersPerSecond : latest?.videoFPS,
                                  unit: audio ? "PCM buffers/s" : "FPS"))
                            .monospacedDigit()
                        if audio {
                            Text(rate(latest?.audioFramesPerSecond, unit: "sample frames/s"))
                                .font(.caption).monospacedDigit()
                        }
                        Chart(points) { point in
                            if let value = audio ? point.audioBuffersPerSecond : point.videoFPS {
                                LineMark(x: .value("時間", point.id), y: .value(audio ? "Buffers/s" : "FPS", value))
                                    .foregroundStyle(audio ? Color.green : Color.blue)
                            }
                        }
                        .frame(height: 120)
                        .chartYScale(domain: .automatic(includesZero: true))
                        .accessibilityLabel(audio ? "混音輸出 buffer 速率" : "混合輸出影格速率")
                    }
                }
            }
            Text("速率由相鄰快照計算，保留最多 60 筆。這是編碼前 Mixer 輸出；系統直接錄製不經 Mixer，沒有這組資料。首次取樣與舊版未回報計數時不補零。")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 格式化有效速率；缺少差分基準時顯示等待，不能以零取代未知。
    private func rate(_ value: Double?, unit: String) -> String {
        value.map { String(format: "%.1f %@", $0, unit) } ?? "等待有效速率取樣"
    }
}

/// 設定、實測 Mixer 資料、編碼事件與傳輸完成分開呈現；缺值不轉成零。
struct StreamDiagnosticsSections: View {
    /// 由設備頁前景採樣提供時間，避免每個區塊各自啟動計時器。
    let now: Date
    @ObservedObject private var model = StreamDiagnosticsModel.shared
    var body: some View {
        SettingsDashboardCard("串流格式與 RTMP 傳輸") {
            if model.snapshots.isEmpty {
                Text("尚未收到串流診斷。開始擷取後每五秒更新；ReplayKit 需連上主 App Socket。")
                    .foregroundStyle(.secondary)
            }
            ForEach(["ReplayKit", "ScreenCaptureKit"], id: \.self) { source in
                if let value = model.snapshots[source] {
                    DisclosureGroup(source) {
                        if source == "ScreenCaptureKit" {
                            CapturePipelineStatusView(sampledAt: value.sampledAt, now: now)
                        } else {
                            let age = max(0, now.timeIntervalSince(value.sampledAt))
                            Text("距取樣 \(Int(age)) 秒" + (age > 15 ? " · 已過期，以下為歷史資料" : ""))
                                .foregroundStyle(age > 15 ? Color.orange : Color.secondary)
                        }
                        Text("Session：\(value.session.uuidString)").font(.caption2)
                        Text("最後取樣狀態：\(value.phase)")
                        detail("Mixer 影片實測", value.mixerVideo)
                        if source == "ScreenCaptureKit" {
                            detail("加工 worker 忙碌比例", value.videoProcessingLoad.map {
                                String(format: "%.1f%% · 最近 %.1f 秒中忙碌 %.2f 秒", $0.busyPercent, $0.intervalSeconds, $0.busySeconds)
                                + ($0.inFlight ? " · 取樣時仍在加工" : "")
                            } ?? "等待完整取樣區間，或此管線未提供")
                            Text("包含加工與同步等待，不是 CPU／GPU 使用率；停止後數值為最後取樣歷史。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        detail("畫面加工", value.videoProcessing)
                        detail("VT 首筆同幀時間", encoderTiming(value.firstEncoderTiming))
                        detail("VT 最新同幀時間", encoderTiming(value.lastEncoderTiming))
                        detail("影片編碼設定", value.videoSettings)
                        detail("實際編碼輸出格式", encodedVideo(value))
                        detail("編碼器交付影格累計", value.encodedVideoFrames.map(String.init))
                        detail("RTMP 影片入列事件累計", value.videoMessagesQueued.map(String.init))
                        detail("Mixer PCM 實測", value.mixerAudio)
                        detail("混音輸出取樣率", value.mixerAudioSampleRate.map { String(format: "%.0f Hz", $0) })
                        detail("音訊編碼設定", value.audioSettings)
                        detail("實際音訊編碼輸出格式", encodedAudio(value))
                        if let encoding = value.encoding {
                            detail("影片 RTMP 入列時間", mediaTiming(encoding.videoTiming))
                            detail("音訊 RTMP 入列時間", mediaTiming(encoding.audioTiming))
                            detail("編碼觀測世代", "\(encoding.generation) · 取樣時 publishing=\(encoding.isPublishing)")
                            detail("影片格式變更時間", encoding.videoFormatChangedAt?.formatted())
                            detail("音訊格式變更時間", encoding.audioFormatChangedAt?.formatted())
                            detail("最近壓縮影片輸出", observedTime(encoding.lastVideoOutputAt))
                            detail("最近壓縮音訊輸出", observedTime(encoding.lastAudioOutputAt))
                            detail("壓縮影片樣本／音訊 packet 累計", "\(encoding.videoFrames) / \(encoding.audioPackets)")
                            detail("壓縮 payload 累計（影片／音訊）", "\(encoding.videoBytes) / \(encoding.audioBytes) bytes")
                        }
                        detail("連線世代", value.generation.map(String.init))
                        detail("本機待完成", bytes(value.queuedBytes))
                        detail("本機完成", bytes(value.completedBytes))
                        detail("失敗批次完整大小", bytes(value.failedBatchBytes))
                        detail("完成／失敗批次", value.completedBatches.flatMap { completed in value.failedBatches.map { "\(completed) / \($0)" } })
                        detail("最近完成回呼耗時", value.lastCompletionMilliseconds.map { String(format: "%.2f ms", $0) })
                        detail("RTMP chunk 數／音訊訊息數／伺服器 ACK", nil)
                        Text("編碼設定不保證已產出。Mixer 像素與色彩資料屬編碼前畫面；批次不是 chunk。本機完成不代表伺服器收到或成功解碼；失敗批次可能已部分傳出。重連後依連線世代重新計數。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// 明確區分來源時間、RTMP 相對時間與本機入列結果；不推算跨軌口型差。
    private func mediaTiming(_ value: RTMPMediaTimingDiagnostics?) -> String? {
        guard let value else { return nil }
        func sample(_ value: RTMPMediaTimingSample?) -> String {
            guard let value else { return "尚無資料" }
            return "#\(value.sequence) 來源 PTS/DTS：\(seconds(value.sourcePTSSeconds)) / \(seconds(value.sourceDTSSeconds))；RTMP PTS/DTS：\(seconds(value.generatedPTSSeconds)) / \(seconds(value.generatedDTSSeconds))；入列：\(value.accepted)；音訊整批 duration：\(seconds(value.preferredDurationSeconds))"
        }
        return "接受 \(value.accepted)／拒絕 \(value.rejected)\n首筆嘗試：\(sample(value.firstAttempt))\n首筆成功：\(sample(value.firstAccepted))\n最新：\(sample(value.lastAttempt))\n入列不代表伺服器收到；兩軌最新樣本不能直接比較同步。"
    }

    /// 顯示 VT 同次提交／回呼，耗時包含編碼器內部等待。
    private func encoderTiming(_ value: VideoEncoderTimingSample?) -> String? {
        guard let value else { return nil }
        return "Session：\(value.session)\n輸入 PTS：\(seconds(value.inputPTSSeconds))；輸出 PTS/DTS：\(seconds(value.outputPTSSeconds)) / \(seconds(value.outputDTSSeconds))\n提交至回呼：\(String(format: "%.2f", value.elapsedMilliseconds)) ms"
    }

    /// 無效或缺漏時間保持未知，不以零冒充。
    private func seconds(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "未知" }
        return String(format: "%.6f s", value)
    }

    /// 保留傳輸計數的原始 bytes 與 nil，讓明細統一處理未提供資料。
    private func bytes(_ value: Int?) -> String? {
        value.map { "\($0) bytes" }
    }

    /// 格式來自壓縮樣本，色彩附件缺漏不以設定或 Mixer 像素格式補值。
    private func encodedVideo(_ snapshot: StreamDiagnosticsSnapshot) -> String {
        guard let encoding = snapshot.encoding else { return "未提供編碼快照（舊版來源或無 RTMP 管線）" }
        guard let video = encoding.video else { return "此發布世代尚未觀測到壓縮影片" }
        let codec = video.codec + (video.avcConfiguration.map { ".\($0)" } ?? "")
        let range = video.fullRange.map { $0 ? "Full" : "Video" } ?? "未提供"
        return "\(codec) · \(video.width)×\(video.height) · range=\(range) · primaries=\(video.colorPrimaries ?? "未提供") · transfer=\(video.transferFunction ?? "未提供") · matrix=\(video.yCbCrMatrix ?? "未提供")"
    }

    /// 顯示實際壓縮音訊格式，區分沒有快照與本世代尚未產出壓縮樣本。
    private func encodedAudio(_ snapshot: StreamDiagnosticsSnapshot) -> String {
        guard let encoding = snapshot.encoding else { return "未提供編碼快照（舊版來源或無 RTMP 管線）" }
        guard let audio = encoding.audio else { return "此發布世代尚未觀測到壓縮音訊" }
        return "\(audio.codec) · \(audio.sampleRate) Hz · \(audio.channels) ch · \(audio.framesPerPacket) sample frames/packet（0 表示可變或未指定）"
    }

    /// 顯示原始觀測時間；停止後保持最後快照，不虛構新的輸出時間。
    private func observedTime(_ time: Date?) -> String? {
        time?.formatted()
    }
    /// 建立可選取的診斷明細列，缺值統一顯示「未提供」。
    private func detail(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "未提供").font(.caption).textSelection(.enabled)
        }
    }
}

/// 兩個 ScreenCaptureKit 診斷入口共用生命週期；停止後凍結快照，不持續計算過期。
struct CapturePipelineStatusView: View {
    @ObservedObject private var capture = CaptureCoordinator.shared
    let sampledAt: Date?
    let now: Date

    var body: some View {
        let status = CapturePipelineStatus.resolve(phase: capture.phase,
                                                  failed: capture.streamTelemetry.failed,
                                                  sampledAt: sampledAt, now: now)
        Text(status.text)
            .font(.caption)
            .foregroundStyle(status.isStale ? Color.orange : Color.secondary)
    }
}
