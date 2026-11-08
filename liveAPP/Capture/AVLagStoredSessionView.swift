import Foundation
import SwiftUI

/// 已保存 session 的分段清單；整場以 session 分組，不把每個子檔當成獨立場次。
struct AVLagStoredSessionView: View {
    let summary: AVLagSessionSummary
    @State private var documents: [AVLagReportDocument] = []
    @State private var isLoading = true

    var body: some View {
        List {
            Section(AppLanguage.localized("avLag.stored.summary")) {
                row(AppLanguage.localized("avLag.stored.started"),
                    summary.startedAt.formatted(date: .abbreviated, time: .standard))
                if let endedAt = summary.endedAt {
                    row(AppLanguage.localized("avLag.stored.ended"),
                        endedAt.formatted(date: .abbreviated, time: .standard))
                }
                row(AppLanguage.localized("avLag.stored.segments"), "\(summary.segments.count)")
                row(AppLanguage.localized("avLag.stored.samples"), "\(summary.sampleCount)")
                row(AppLanguage.localized("avLag.stored.size"),
                    ByteCountFormatter.string(fromByteCount: Int64(summary.bytes), countStyle: .file))
                if summary.truncatedBefore {
                    Text(AppLanguage.localized("avLag.stored.truncated"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section(AppLanguage.localized("avLag.stored.segments")) {
                if isLoading {
                    ProgressView()
                } else if documents.isEmpty {
                    Text(AppLanguage.localized("avLag.stored.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(documents, id: \.segmentIndex) { document in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(String(format: AppLanguage.localized("avLag.stored.segment"),
                                            document.segmentIndex + 1))
                                Spacer()
                                Text(document.complete
                                    ? AppLanguage.localized("avLag.stored.complete")
                                    : AppLanguage.localized("avLag.stored.inProgress"))
                                    .font(.caption)
                                    .foregroundStyle(document.complete ? Color.secondary : Color.orange)
                            }
                            Text("\(document.sampleCount) samples")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ShareLink(item: document.jsonText) {
                                Label(AppLanguage.localized("avLag.stored.share"),
                                      systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(AppLanguage.localized("avLag.stored.title"))
        .task {
            documents = await AVLagReportStore.shared.documents(for: summary.id)
            isLoading = false
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }
}
