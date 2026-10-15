#if os(iOS)
import SwiftUI

/// 本機系統報告入口：不自動上傳，分享由使用者操作。
struct MetricReportsView: View {
    @ObservedObject private var store = MetricReports.shared
    var body: some View {
        List {
            Section {
                Text("主 App 的系統報告；效能統計通常涵蓋前 24 小時，並非即時監控。沒有報告不表示沒有異常。")
                Text("保留最近 30 份／最多 20 MB，僅保存於本機。重新整理不會要求系統產生報告。")
                Text("儲存位置：主 App 的 Documents/MetricReports，不依賴 App Group。")
            }.font(.caption).foregroundStyle(.secondary)
            if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
            if store.reports.isEmpty { Text("尚未收到 MetricKit 報告，等待系統提供。") }
            ForEach(store.reports) { entry in
                NavigationLink {
                    MetricReportDetailView(entry: entry)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.kind)
                        Text("收到：" + entry.received.formatted()).font(.caption)
                        Text("涵蓋：" + entry.period).font(.caption)
                        Text(entry.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("系統效能報告")
        .toolbar { Button("重新整理") { store.refresh() } }
        .onAppear { store.refresh() }
    }
}

/// 按需讀取並解讀單份報告；原文獨立查看，解析失敗仍保留原文入口。
private struct MetricReportDetailView: View {
    let entry: MetricReportEntry
    @State private var content: String?
    @State private var analysis: MetricReportAnalysis?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("報告概覽") {
                Text(entry.kind).font(.headline)
                Text("收到：" + entry.received.formatted())
                Text("系統歷史報告，並非即時監控；接收時間不等於事件時間。")
                    .font(.caption).foregroundStyle(.secondary)
                if let content {
                    NavigationLink("查看原始 JSON") {
                        ScrollView {
                            Text(content).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding()
                        }
                        .navigationTitle("原始 JSON")
                    }
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if let analysis {
                if !analysis.missing.isEmpty {
                    Section("本份報告的限制") {
                        Text("未提供：" + analysis.missing.joined(separator: "、"))
                        Text("缺少指標不代表數值為零或沒有異常。磁碟大小不能用來判定 RAM 的持有來源。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let fraction = analysis.deviceStorageFraction {
                    Section("整台裝置儲存空間") {
                        ProgressView(value: fraction, total: 1)
                            .tint(.blue)
                            .accessibilityLabel("裝置已用容量")
                            .accessibilityValue(String(format: "%.1f%%", fraction * 100))
                        Text(String(format: "已使用 %.1f%% · 可用 %.1f%%", fraction * 100, (1 - fraction) * 100))
                        Text("這是整台裝置的容量比例，不是 App 或記憶體占用比例。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(analysis.sections) { section in
                    Section(section.title) {
                        Text(section.explanation).font(.caption).foregroundStyle(.secondary)
                        ForEach(section.fields) { field in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(field.title).font(.subheadline)
                                Text(field.value).font(.headline).textSelection(.enabled)
                                Text(field.id).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("報告版本與裝置") {
                    Text("以下版本來自報告本身；接收時的 checkout 資訊保留在原始 JSON，兩者可能不同。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(analysis.metadata) { field in
                        VStack(alignment: .leading) {
                            Text(field.title).font(.caption).foregroundStyle(.secondary)
                            Text(field.value).textSelection(.enabled)
                        }
                    }
                }
            } else if errorMessage == nil {
                ProgressView("正在解讀報告…")
            }
        }
        .navigationTitle(entry.kind)
        .toolbar { ShareLink("分享 JSON", item: entry.url) }
        .task(id: entry.id) {
            do {
                let text = try await MetricReports.shared.contents(of: entry)
                guard !Task.isCancelled else { return }
                content = text
                let parsed = try await Task.detached(priority: .utility) {
                    try MetricReportAnalysis.parse(text)
                }.value
                guard !Task.isCancelled else { return }
                analysis = parsed
            } catch {
                errorMessage = "報告無法讀取或解讀：" + error.localizedDescription
            }
        }
    }
}
#endif
