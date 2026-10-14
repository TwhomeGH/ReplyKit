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

/// 按需載入單份 JSON；檔案已清除時顯示讀取錯誤。
private struct MetricReportDetailView: View {
    /// 選取時的摘要與路徑；不保證檔案之後仍存在。
    let entry: MetricReportEntry
    @State private var content = "讀取中…"
    var body: some View {
        ScrollView {
            Text(content).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle(entry.kind)
        .toolbar { ShareLink("分享 JSON", item: entry.url) }
        .task {
            do { content = try await MetricReports.shared.contents(of: entry) }
            catch { content = "報告無法讀取，可能已超出保留期限：" + error.localizedDescription }
        }
    }
}
#endif
