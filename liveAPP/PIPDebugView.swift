import SwiftUI

/// 本機畫面測試：未啟動時只更新預覽；不呼叫 TTS 或向外傳送訊息。
struct PIPDebugView: View {
    @ObservedObject private var service = PIPService.shared
    @State private var user = "測試觀眾"
    @State private var message = "這是測試訊息"
    @State private var primary = true
    @State private var previewMessage = "這是測試訊息"
    @State private var previewAvatar: UIImage?
    @ObservedObject private var testService = PIPTestService.shared

    var body: some View {
        Form {
            Section("畫面預覽") {
                Image(uiImage: preview).resizable().aspectRatio(1.5, contentMode: .fit)
                    .frame(maxWidth: 420).frame(maxWidth: .infinity)
                Text("預覽使用固定範例，不會啟動 PiP；系統控制鈕不包含在輸出影像中。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("PiP 控制") {
                Button("啟動聊天室 PiP") { service.startPiP(size: CGSize(width: 300, height: 200)) }
                    .disabled(service.isPiPActive || testService.isRunning)
                Button("停止目前 PiP", role: .destructive) { service.stopPiP() }
                    .disabled(!service.isPiPActive)
                Text(service.isPiPActive ? "測試訊息會送進目前聊天室；保活模式只更新下方預覽。" : "尚未啟動：測試只更新預覽。")
                    .font(.caption)
            }
            Section("測試訊息") {
                TextField("名稱", text: $user)
                TextField("內容", text: $message)
                Toggle("主要訊息", isOn: $primary)
                Button("顯示測試訊息") { submit(message) }
                Button("測試長文字") { submit(String(repeating: "長訊息換行測試。", count: 12)) }
                Button("測試表情符號") { submit("🎉 測試訊息 ☕️ 🐿️") }
                Button("測試頭貼＋表情") { submit("🎉 測試訊息 ☕️ 🐿️", avatar: Self.testAvatar) }
                Text("測試名稱會加上標記，不觸發朗讀。次要訊息遵循目前的顯示設定。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("獨立播放器測試") {
                DisclosureGroup("30 FPS 測試播放器") {
                    Button("啟動獨立播放器") {
                        PIPTestService.shared.startPiPTest(size: CGSize(width: 300, height: 200))
                    }.disabled(service.isPiPActive || testService.isRunning)
                    Button("停止獨立播放器") {
                        PIPTestService.shared.stopPiP()
                    }.disabled(!testService.isRunning)
                    Text("與正式 PiP 互斥，離開此頁會持續運行，請按停止或使用系統關閉鈕。")
                        .font(.caption)
                }
            }
        }
        .navigationTitle("訊息與畫面測試")

    }

    /// 只注入現有聊天室；不偷偷建立服務工作階段或送出遠端訊息。
    private func submit(_ text: String, avatar: UIImage? = nil) {
        previewMessage = text
        previewAvatar = avatar
        if service.isPiPActive && !service.isKeepaliveMode {
            service.addMessage(user: "[測試] \(user)", msg: text,
                               avatarImage: avatar, isMain: primary)
        }
    }

    /// 本機測試頭貼，避免測試訊息依賴網路圖片。
    private static let testAvatar: UIImage = {
        let size = CGSize(width: 60, height: 60)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemTeal.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
            let text = "測" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 30),
                .foregroundColor: UIColor.white,
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2,
                                  y: (size.height - textSize.height) / 2),
                      withAttributes: attributes)
        }
    }()

    /// 與正式畫面共用 renderer，預覽不改動目前聊天佇列。
    private var preview: UIImage {
        let summary = !primary && PIPDisplaySettings.secondaryMode == "summary"
        let hidden = !primary && PIPDisplaySettings.secondaryMode == "hidden"
        return PIPPreviewFrameRenderer.render(scene: .init(
            time: .init(elapsedString: "00:12:34", nowTimeText: "12:34:56", nowTimeLabel: "現在時間",
                statusText: "直播中", statusEnded: false, viewerCount: 128,
                isReconnecting: false, reconnectText: "", secondaryNotice: summary ? "[測試] \(user)：\(previewMessage)" : nil),
            ad: nil,
            chatMain: primary ? ("[測試] \(user)", previewMessage, 18, previewAvatar) : nil,
            chatSecondary: !primary && !summary && !hidden ? ("[測試] \(user)", previewMessage, 15, previewAvatar) : nil))
    }
}
