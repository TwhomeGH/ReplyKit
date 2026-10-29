import SwiftUI

/// 日常 PiP 操作入口，與測試工具分離。
struct PIPView: View {
    @ObservedObject private var service = PIPService.shared

    var body: some View {
        Form {
            Section("子母畫面") {
                Text(service.isPiPActive ? "目前正在顯示子母畫面" : "子母畫面尚未啟動")
                Button("啟動聊天室 PiP") { service.startPiP(size: CGSize(width: 300, height: 200)) }
                    .disabled(service.isPiPActive)
                Button("啟動保活 PiP") { service.startKeepalivePiP(size: CGSize(width: 300, height: 200)) }
                    .disabled(service.isPiPActive)
                Button("停止 PiP", role: .destructive) { service.stopPiP() }
            }
            PIPKeepaliveSettingsSection()
            Section("外觀") {
                NavigationLink("PiP 排版設定") { PIPLayoutSettingsView() }
            }
            Section("進階") {
                NavigationLink("訊息與畫面測試") { PIPDebugView() }
                    .disabled(service.isPiPActive)
            }
        }
        .navigationTitle("子母畫面 PiP")
    }
}

/// 共用設定區塊；只通知已存在的服務，不因修改偏好建立 PiP 資源。
struct PIPKeepaliveSettingsSection: View {
    @AppStorage("pipKeepaliveSeconds", store: userDefaults) private var seconds = 5.0

    var body: some View {
        Section("保活更新間隔") {
            Stepper(value: $seconds, in: 1...60, step: 1) {
                Text("每 \(Int(PIPRenderPolicy.keepaliveSeconds(seconds))) 秒更新一次")
            }
            Button("恢復預設 5 秒") { seconds = 5 }
            Text("可設定 1–60 秒。間隔越長，畫面更新越少；時間顯示也會一起降低頻率。贊助動畫期間會暫時提高更新率。此設定不保證系統允許 App 永久背景執行。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            let normalized = PIPRenderPolicy.keepaliveSeconds(seconds)
            if seconds != normalized { seconds = normalized }
        }
        .onChange(of: seconds) { _ in
            PIPService.diagnosticInstance?.applyKeepaliveInterval()
        }
    }
}
