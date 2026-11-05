import SwiftUI

/// 日常 PiP 操作入口，與測試工具分離。
struct PIPView: View {
    @ObservedObject private var service = PIPService.shared
    @AppStorage("pipHideSystemControls", store: userDefaults) private var hideSystemControls = false

    var body: some View {
        Form {
            Section("子母畫面") {
                // 圖示與文字同時表達狀態，不只依賴顏色判斷。
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(service.isPiPActive ? "子母畫面正在顯示" : "子母畫面未啟動")
                            .font(.headline)
                        Text(service.isPiPActive ? "可使用下方按鈕停止顯示" : "選擇聊天室或保活模式開始")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: service.isPiPActive ? "pip.fill" : "pip")
                        .foregroundStyle(service.isPiPActive ? Color.green : Color.secondary)
                        .font(.title2)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                Button("啟動聊天室 PiP") { service.startPiP(size: CGSize(width: 300, height: 200)) }
                    .disabled(service.isPiPActive)
                Button("啟動保活 PiP") { service.startKeepalivePiP(size: CGSize(width: 300, height: 200)) }
                    .disabled(service.isPiPActive)
                Button(role: .destructive) { service.stopPiP() } label: {
                    Label("停止 PiP", systemImage: "stop.circle")
                        .foregroundStyle(service.isPiPActive ? Color.red : Color.secondary)
                }
                .disabled(!service.isPiPActive)
            }

            Section("PiP 系統控制列") {
                Toggle("隱藏關閉與返回按鈕", isOn: $hideSystemControls)
                if hideSystemControls {
                    Text("PiP 視窗內將沒有關閉或返回 App 的按鈕；請回到 App 的「子母畫面」頁按「停止 PiP」。「停止 PiP」會真正結束系統 PiP，不會留下無法關閉的視窗。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("保留系統的關閉與返回按鈕；畫面內容會避開這兩個按鈕。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("設定立即套用；若目前 PiP 沒有反應，請停止後重新啟動。此樣式使用系統非公開設定，需要 iOS 16 以上。")
                    .font(.caption).foregroundStyle(.orange)
            }
            .onChange(of: hideSystemControls) { _ in
                PIPService.diagnosticInstance?.applySystemControlsStyle()
            }

            PIPDisplaySettingsSection()
            PIPKeepaliveSettingsSection()
            Section("外觀") {
                NavigationLink("PiP 排版設定") { PIPLayoutSettingsView() }
            }
            Section("進階") {
                NavigationLink("訊息與畫面測試") { PIPDebugView() }
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
