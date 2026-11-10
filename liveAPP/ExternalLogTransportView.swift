import SwiftUI

/// 外部日誌的通道設定；只控制主 App 對外轉送，不改擴展的保存與回報。
struct ExternalLogTransportView: View {
    @AppStorage("externalLogTransport", store: userDefaults) private var transport = "http"
    @ObservedObject private var server = SocketServer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("外部日誌傳輸", selection: $transport) {
                Text("HTTP Web").tag("http")
                Text("已連線 Socket").tag("socket")
            }
            if transport == "socket" {
                Text(server.externalLogSubscribers == 0 ? "未連線：沒有已訂閱的外部工具，不累積離線日誌。"
                     : "已訂閱外部工具：\(server.externalLogSubscribers) 個")
                Text("慢連線略過批次：\(server.externalLogDropped)").font(.caption)
                Text("外部工具需傳送 subscribeExternalLogs 訂閱。ReplyKit 會阻斷回送迴圈：擴展送出的日誌不會再被回送給擴展自身；只有已訂閱的外部工具會收到 externalLogBatch／diagnostic。慢連線會略過新日誌，不影響本地保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: transport) { _ in
            RemoteLogBuffer.shared.clear()
            RemoteLogSender.shared.stop()
        }
    }
}
