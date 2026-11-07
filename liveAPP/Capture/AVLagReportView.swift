import SwiftUI
import UIKit

/// 裝置頁入口：顯示目前 A/V 內容延遲，並提供可帶去回放修正工具的 JSON。
struct AVLagReportView: View {
    @ObservedObject private var model = AVLagModel.shared
    @State private var reportText = ""
    @State private var copied = false

    var body: some View {
        List {
            Section(AppLanguage.localized("avLag.current")) {
                if let latest = model.latest {
                    row("session", latest.session)
                    row("video content age", seconds(latest.videoContentAge))
                    row("video idle age", seconds(latest.videoIdleAge))
                    row("audio content age", seconds(latest.audioContentAge))
                    row("video queue age", seconds(latest.videoQueueAge))
                    row("video queue oldest", seconds(latest.videoQueueOldestAge))
                    row("video process age", seconds(latest.videoProcessAge))
                    row("video source age", seconds(latest.videoSourceAge))
                    row("video PTS - audio PTS", seconds(latest.sourcePTSDelta))
                    row("content age jump", seconds(latest.contentAgeJump))
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
        }
        .navigationTitle(AppLanguage.localized("avLag.title"))
        .onAppear { refreshReport() }
        .onChange(of: model.samples.count) { _ in refreshReport() }
    }

    private func refreshReport() {
        reportText = model.reportJSON()
        copied = false
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
