import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// 設定備份、分享與還原預覽；即使掉簽，Documents 中的檔案仍可由「檔案」搬走。
@MainActor
struct SettingsBackupView: View {
    @ObservedObject private var manager = SettingsBackupManager.shared
    @State private var importing = false
    @State private var includeSecrets = false
    @State private var preview: SettingsBackupDocument?
    @State private var exported: URL?
    @State private var confirming = false

    var body: some View {
        Form {
            Section("側載到期／重新安裝前") {
                Label("先搬資料，再刪除 App", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.headline)
                Text("若掉簽後無法開啟 App，請到「檔案 → 我的 iPhone／iPad → 松鼠推流」，將 ConfigBackups 設定備份、CompressedVideos 已壓縮影片、ScreenRecordings 本地錄影複製到 iCloud Drive 或其他位置。")
                Text("刪除 App 會一併刪除其中資料。請先確認副本可讀；設定 JSON 不包含影片。舊錄影搬移若失敗，請先在本地錄影頁匯出。")
                    .foregroundStyle(.orange)
            }
            Section("自動備份") {
                Text("設定變更後約兩秒保存，不必開啟此頁。App 被凍結或無法啟動時不會更新；請確認最近成功時間。")
                if let date = manager.lastSaved {
                    Text("最近成功：\(date.formatted(date: .abbreviated, time: .standard))")
                } else { Text("尚無成功備份") }
                Text("位置：Documents/ConfigBackups。自動保存最新與前一份，不含連線網址、串流金鑰及推流配置庫。")
                    .font(.footnote)
                Button("立即備份") { manager.saveAutomatic() }
                    .disabled(manager.restorePending)
            }
            Section("匯出與還原") {
                Toggle("匯出包含敏感設定", isOn: $includeSecrets)
                Text("包含時，JSON 會以明文保存連線網址、金鑰與推流配置庫；請勿公開分享。之前建立的敏感備份不會因關閉此選項而自動刪除。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("匯出目前設定") {
                    do { exported = try manager.export(includesSecrets: includeSecrets) }
                    catch { manager.report(error) }
                }.disabled(manager.restorePending)
                if let exported { ShareLink("分享匯出的設定", item: exported) }
                Button("從 JSON 匯入") { importing = true }
                    .disabled(manager.restorePending)
                Text("還原只套用備份內的項目，不清空其他設定。請先停止直播、錄影、壓縮與 PiP；確認後需完整關閉 App 再重新開啟。")
                    .font(.footnote)
                if let message = manager.message { Text(message).foregroundStyle(.orange) }
                if manager.restorePending {
                    Button("取消待還原設定", role: .destructive) {
                        do {
                            try manager.cancelRestore()
                        } catch { manager.report(error) }
                    }
                }
            }
            if let preview {
                Section("還原預覽") {
                    Text("備份時間：\(preview.createdAt.formatted(date: .abbreviated, time: .standard))")
                    Text("共享偏好 \(preview.shared.count) 項，主 App 偏好 \(preview.standard.count) 項")
                    Text(preview.includesSecrets ? "包含敏感設定" : "不包含敏感設定")
                    DisclosureGroup("查看設定欄位（不顯示值）") {
                        Text((preview.shared.keys.map { "shared.\($0)" } + preview.standard.keys.map { "standard.\($0)" })
                            .sorted().joined(separator: "\n"))
                            .font(.caption).textSelection(.enabled)
                    }
                    Button("確認於下次啟動還原") { confirming = true }
                        .disabled(manager.restorePending || preview.count == 0)
                }
            }
            Section("已保存的備份") {
                ForEach(manager.files, id: \.self) { url in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(url.lastPathComponent).font(.caption)
                        HStack {
                            ShareLink("分享", item: url)
                            Button("預覽還原") { read(url) }
                                .disabled(manager.restorePending)
                        }.buttonStyle(.borderless)
                    }
                }
                Text("最多五個固定檔案：最新、前一份、還原前、一般匯出、敏感匯出；重新匯出會更新同名檔。請另存需要長期保留的版本。")
                    .font(.footnote)
            }
        }
        .navigationTitle("備份與還原")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { manager.start(); manager.refresh() }
        .sheet(isPresented: $importing) {
            SettingsBackupPicker { url in
                importing = false
                if let url { read(url) }
            }
        }
        .confirmationDialog("套用後需重新開啟 App。是否排定還原？", isPresented: $confirming, titleVisibility: .visible) {
            Button("排定還原") {
                guard let preview else { return }
                do { try manager.stageRestore(preview); self.preview = nil }
                catch { manager.report(error) }
            }
        }
    }

    /// 檔案供應商先匯入副本，再做有界讀取與完整驗證，失敗不留下舊預覽。
    private func read(_ url: URL) {
        preview = nil
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { preview = try SettingsBackupStorage.read(url) }
        catch { manager.report(error) }
    }
}

/// 使用匯入副本模式，避免雲端供應商的原地開啟行為讓 JSON 選取沒有回應。
private struct SettingsBackupPicker: UIViewControllerRepresentable {
    let completion: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (URL?) -> Void
        init(completion: @escaping (URL?) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion(urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(nil) }
    }
}
