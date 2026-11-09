import Foundation
import SwiftUI
import UIKit

/// 裝置頁入口：顯示目前 A/V 內容延遲，並提供可帶去回放修正工具的 JSON。
struct AVLagReportView: View {
    @ObservedObject private var model = AVLagModel.shared
    @State private var reportText = ""
    @State private var copied = false
    @State private var summaries: [AVLagSessionSummary] = []
    @State private var pendingDelete: AVLagSessionSummary?

    var body: some View {
        List {
            Section(AppLanguage.localized("avLag.current")) {
                if let latest = model.latest {
                    row("session", latest.session)
                    row("video content age", seconds(latest.videoContentAge))
                    row("video idle age", seconds(latest.videoIdleAge))
                    row("audio content age", seconds(latest.audioContentAge))
                    row("video queue age", seconds(latest.videoQueueAge))
                    row("video queue oldest", latest.videoQueueOldestAge.map { seconds($0) }
                        ?? AppLanguage.localized("avLag.queueEmpty"))
                    row("video process age", seconds(latest.videoProcessAge))
                    row("video source age", seconds(latest.videoSourceAge))
                    row("video PTS - audio PTS", seconds(latest.sourcePTSDelta))
                    row("content age jump", latest.contentAgeJump.map { seconds($0) }
                        ?? AppLanguage.localized("avLag.noJump"))
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
                ShareLink(item: reportText) {
                    Label(AppLanguage.localized("avLag.share"), systemImage: "square.and.arrow.up")
                }
                Text(String(format: AppLanguage.localized("avLag.sampleCount"), model.samples.count))
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
        copied = false
    }

    private func reloadSummaries() async {
        let activeSession = model.isCapturing ? model.session : nil
        summaries = await AVLagReportStore.shared.summaries(activeSessionID: activeSession)
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
