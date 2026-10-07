import SwiftUI

/// 每個來源僅保存一筆快照；較舊取樣不可覆蓋較新的 session 資料。
@MainActor final class StreamDiagnosticsModel: ObservableObject {
    static let shared = StreamDiagnosticsModel()
    @Published private(set) var snapshots: [String: StreamDiagnosticsSnapshot] = [:]
    @Published private(set) var receivedAt: [String: Date] = [:]

    func record(_ snapshot: StreamDiagnosticsSnapshot, now: Date = Date()) {
        guard snapshot.schemaVersion == 1,
              ["ReplayKit", "ScreenCaptureKit"].contains(snapshot.source),
              snapshot.sampledAt <= now.addingTimeInterval(5),
              snapshots[snapshot.source].map({ $0.sampledAt < snapshot.sampledAt }) ?? true else { return }
        snapshots[snapshot.source] = snapshot
        receivedAt[snapshot.source] = now
    }
}

/// 設定、實測 Mixer 資料、編碼事件與傳輸完成分開呈現；缺值不轉成零。
struct StreamDiagnosticsSections: View {
    @ObservedObject private var model = StreamDiagnosticsModel.shared
    var body: some View {
        Section("串流格式與 RTMP 傳輸") {
            if model.snapshots.isEmpty {
                Text("尚未收到串流診斷。開始擷取後每五秒更新；ReplayKit 需連上主 App Socket。")
                    .foregroundStyle(.secondary)
            }
            ForEach(["ReplayKit", "ScreenCaptureKit"], id: \.self) { source in
                if let value = model.snapshots[source] {
                    DisclosureGroup(source) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let age = max(0, context.date.timeIntervalSince(value.sampledAt))
                            Text("距取樣 \(Int(age)) 秒" + (age > 15 ? " · 已過期，以下為歷史資料" : ""))
                                .foregroundStyle(age > 15 ? Color.orange : Color.secondary)
                        }
                        Text("Session：\(value.session.uuidString)").font(.caption2)
                        Text("最後取樣狀態：\(value.phase)")
                        detail("Mixer 影片實測", value.mixerVideo)
                        detail("影片編碼設定", value.videoSettings)
                        detail("實際編碼輸出格式", nil)
                        detail("編碼器交付影格累計", value.encodedVideoFrames.map(String.init))
                        detail("RTMP 影片入列事件累計", value.videoMessagesQueued.map(String.init))
                        detail("Mixer PCM 實測", value.mixerAudio)
                        detail("混音輸出取樣率", value.mixerAudioSampleRate.map { String(format: "%.0f Hz", $0) })
                        detail("音訊編碼設定", value.audioSettings)
                        detail("實際音訊編碼輸出格式", nil)
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

    private func bytes(_ value: Int?) -> String? {
        value.map { "\($0) bytes" }
    }
    private func detail(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "未提供").font(.caption).textSelection(.enabled)
        }
    }
}
