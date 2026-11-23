import Foundation
import SwiftUI
import UIKit
import HaishinKit

/// 裝置頁入口：顯示來源時間戳與處理耗時，提供診斷 JSON（不能直接用作回放校正曲線）。
struct AVLagReportView: View {
    @ObservedObject private var model = AVLagModel.shared
    @ObservedObject private var diagnostics = StreamDiagnosticsModel.shared
    @State private var reportText = ""
    @State private var reportFileURL: URL?
    @State private var lastFileRefresh = Date.distantPast
    @State private var copied = false
    @State private var summaries: [AVLagSessionSummary] = []
    @State private var pendingDelete: AVLagSessionSummary?

    var body: some View {
        List {
            Section(AppLanguage.localized("avLag.current")) {
                if let latest = model.latest {
                    row("session", latest.session)
                    row("影片 callback − 來源 PTS（時鐘未驗證）", seconds(latest.videoContentAge))
                    row("影片來源回呼距今", seconds(latest.videoIdleAge))
                    row("音訊 callback − 來源 PTS（時鐘未驗證）", seconds(latest.audioContentAge))
                    row("video queue age", seconds(latest.videoQueueAge))
                    row("video queue oldest", latest.videoQueueOldestAge.map { seconds($0) }
                        ?? AppLanguage.localized("avLag.queueEmpty"))
                    row("video process age", seconds(latest.videoProcessAge))
                    row("video source age", seconds(latest.videoSourceAge))
                    row("video PTS - audio PTS", seconds(latest.sourcePTSDelta))
                    row("A/V source drift", seconds(latest.sourcePTSDeltaDrift))
                    row("A/V drift per minute", seconds(latest.sourcePTSDeltaPerMinute))
                    row("audio - video host offset", seconds(latest.avClockDrift))
                    row("來源時間戳趨勢（非內容同步）", latest.avSyncState ?? "unknown")
                    row("content age jump", latest.contentAgeJump.map { seconds($0) }
                        ?? AppLanguage.localized("avLag.noJump"))
                    row("實際內容同步", "未量測")
                    row("時鐘可比性", latest.clockComparison ?? "unverified")
                    row("音訊來源回呼距今", seconds(latest.audioIdleAge))
                    row("影片 worker 更新距今", seconds(latest.videoWorkerIdleAge))
                    row("音訊 worker 更新距今", seconds(latest.audioWorkerIdleAge))
                    row("frames", "\(latest.videoFrames) video / \(latest.audioFrames) audio")
                    if let queue = latest.videoQueue {
                        Text(queue).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                } else {
                    Text(AppLanguage.localized("avLag.emptyReport"))
                        .foregroundStyle(.secondary)
                }
            }

            Section(AppLanguage.localized("avLag.purpose")) {
                Text(AppLanguage.localized("avLag.usage"))
                Text(AppLanguage.localized("avLag.zeroSemantics"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(AppLanguage.localized("avLag.pressure.title")) {
                if let item = latestPressure {
                    row(AppLanguage.localized("avLag.pressure.source"), item.source)
                    row(AppLanguage.localized("avLag.pressure.state"), item.pressure.state.rawValue)
                    row(AppLanguage.localized("avLag.pressure.counts"), "\(item.pressure.submitted) / \(item.pressure.callbacks) / \(item.pressure.delivered)")
                    row(AppLanguage.localized("avLag.pressure.pending"), "\(item.pressure.outstandingSubmissions) / \(item.pressure.undeliveredCallbacks)")
                    row(AppLanguage.localized("avLag.pressure.vtPending"), "\(item.pressure.pendingFrames.map(String.init) ?? "未知") / \(item.pressure.highWatermark)")
                    row(AppLanguage.localized("avLag.pressure.queue"), [
                        item.pressure.queued.map { "\($0) frames" },
                        item.pressure.oldestAgeSeconds.map { String(format: "最舊 %.1f ms", $0 * 1000) },
                        item.pressure.maxWaitSeconds.map { String(format: "最長 %.1f ms", $0 * 1000) }
                    ].compactMap { $0 }.joined(separator: " · "))
                    row(AppLanguage.localized("avLag.pressure.elapsed"), item.pressure.lastElapsedMilliseconds.map { String(format: "%.1f ms", $0) } ?? "未知")
                } else {
                    Text(AppLanguage.localized("avLag.pressure.empty"))
                        .foregroundStyle(.secondary)
                }
                Text(AppLanguage.localized("avLag.pressure.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(AppLanguage.localized("avLag.recent.title")) {
                if summaries.isEmpty {
                    Text(AppLanguage.localized("avLag.recent.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(summaries) { summary in
                        NavigationLink {
                            AVLagStoredSessionView(summary: summary)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(summary.startedAt.formatted(date: .abbreviated, time: .shortened))
                                Text("\(summary.segments.count) \(AppLanguage.localized("avLag.stored.segments")) · \(summary.sampleCount) \(AppLanguage.localized("avLag.stored.samples"))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if model.isCapturing, model.session == summary.id {
                                    Text(AppLanguage.localized("avLag.stored.inProgress"))
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                } else if summary.complete {
                                    Text(AppLanguage.localized("avLag.stored.completed"))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(AppLanguage.localized("avLag.stored.incomplete"))
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = summary
                            } label: {
                                Label(AppLanguage.localized("avLag.stored.delete"),
                                      systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Section(AppLanguage.localized("avLag.report")) {
                Button {
                    UIPasteboard.general.string = reportText
                    copied = true
                } label: {
                    Label(
                        copied ? AppLanguage.localized("avLag.copied") : AppLanguage.localized("avLag.copy"),
                        systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                if let reportFileURL {
                    ShareLink(item: reportFileURL) {
                        Label(AppLanguage.localized("avLag.share"), systemImage: "square.and.arrow.up")
                    }
                } else {
                    ShareLink(item: reportText) {
                        Label(AppLanguage.localized("avLag.share"), systemImage: "square.and.arrow.up")
                    }
                }
                Text(String(format: AppLanguage.localized("avLag.sampleCount"), model.samples.count))
                    .font(.caption).foregroundStyle(.secondary)
                Text(AppLanguage.localized("avLag.storage.location"))
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("JSON") {
                    Text(reportText)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section {
                NavigationLink(AppLanguage.localized("avLag.settings.open")) {
                    AVLagSettingsView()
                }
            }
        }
        .navigationTitle(AppLanguage.localized("avLag.title"))
        .onAppear {
            refreshReport()
            Task { await reloadSummaries() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVLagReportStore.didChangeNotification)) { _ in
            Task { await reloadSummaries() }
        }
        .onChange(of: model.samples.count) { _ in refreshReport() }
        .alert(AppLanguage.localized("avLag.stored.deleteTitle"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(AppLanguage.localized("avLag.settings.cancel"), role: .cancel) {
                pendingDelete = nil
            }
            Button(AppLanguage.localized("avLag.stored.deleteConfirm"), role: .destructive) {
                let id = pendingDelete?.id
                pendingDelete = nil
                guard let id else { return }
                Task { await AVLagReportStore.shared.delete(sessionID: id) }
            }
        } message: {
            Text(AppLanguage.localized("avLag.stored.deleteMessage"))
        }
    }

    private func refreshReport() {
        reportText = model.reportJSON()
        // 分享檔不需要跟著每 5 秒的畫面刷新重寫；最多落後一分鐘，避免長場次
        // 在報告頁開著時持續寫入數百 KB。
        if reportFileURL == nil || Date().timeIntervalSince(lastFileRefresh) >= 60 {
            reportFileURL = model.reportFileURL()
            lastFileRefresh = Date()
        }
        copied = false
    }

    private func reloadSummaries() async {
        let activeSession = model.isCapturing ? model.session : nil
        summaries = await AVLagReportStore.shared.summaries(activeSessionID: activeSession)
    }

    /// 優先取 ScreenCaptureKit，沒有時退回 ReplayKit；只讀已收到的低頻快照。
    private var latestPressure: (source: String, pressure: VideoEncoderPressureSnapshot)? {
        for source in ["ScreenCaptureKit", "ReplayKit"] {
            if let snapshot = diagnostics.snapshots[source], let pressure = snapshot.encoderPressure {
                return (source, pressure)
            }
        }
        return nil
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    private func seconds(_ value: Double?) -> String {
        value.map { String(format: "%.3f s", $0) } ?? "unknown"
    }
}
