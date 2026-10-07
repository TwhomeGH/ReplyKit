import ReplayKit
import SwiftUI
import Combine
import os
import Foundation

/// 金鑰顯示狀態僅存在於當次畫面，不寫入偏好設定。
private struct StreamKeyField: View {
    @Binding var text: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var revealed = false

    var body: some View {
        HStack {
            Group {
                if revealed { TextField("Stream Key", text: $text) }
                else { SecureField("Stream Key", text: $text) }
            }
#if os(iOS)
            .textInputAutocapitalization(.never)
#endif
            .autocorrectionDisabled(true)
            .privacySensitive()
            Button { revealed.toggle() } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(revealed ? AppLanguage.localized("home.hideKey") : AppLanguage.localized("home.showKey"))
        }
        .onDisappear { revealed = false }
        .onChange(of: scenePhase) { phase in
            if phase != .active { revealed = false }
        }
    }
}

/// RTMP 設定使用獨立草稿；離開畫面不自動保存或覆寫啟用中的配置。
struct FormView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = StreamConfigManager()
    @State private var draft = StreamConfigurationDraft()
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("stream.config.selectSection")) {
                    Picker("配置", selection: Binding(
                        get: { draft.id },
                        set: { id in
                            if let config = manager.configs.first(where: { $0.id == id }) {
                                draft = StreamConfigurationDraft(config: config)
                            } else { draft = StreamConfigurationDraft() }
                            error = nil
                        }
                    )) {
                        Text("新增配置").tag(UUID?.none)
                        ForEach(manager.configs) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Section(header: Text("stream.rtmp.section")) {
                    TextField("配置名稱", text: $draft.name)
                    TextField("RTMP URL", text: $draft.rtmpURL)
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                        .autocorrectionDisabled(true)
                    StreamKeyField(text: $draft.streamKey)
                    Menu("快速選擇樣本") {
                        Button("自訂SRS") { draft.rtmpURL = "rtmp://192.168.0.102/live" }
                        Button("Twitch") { draft.rtmpURL = "rtmp://live.twitch.tv/app" }
                    }
                }
                Section("配置設定") {
                    if let error { Text(error).foregroundStyle(.red) }
                    Button("新增空白配置") { draft = StreamConfigurationDraft(); error = nil }
                    Button("複製為新草稿") {
                        draft.id = nil
                        draft.name += " 複製"
                        error = nil
                    }
                    if let id = draft.id, let config = manager.configs.first(where: { $0.id == id }) {
                        Button("刪除配置：" + config.name, role: .destructive) {
                            manager.removeConfig(config)
                            draft = StreamConfigurationDraft()
                            error = nil
                        }
                    }
                    Text("編輯與切換配置只更動草稿。儲存並套用後才更新推流設定；刪除配置不會停止目前串流。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("stream.settings.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存並套用") {
                        guard let config = draft.validatedConfig else {
                            error = "請填寫配置名稱、有效的 RTMP／RTMPS 網址與串流金鑰。"
                            return
                        }
                        manager.saveAndActivate(config)
                        dismiss()
                    }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let config = manager.activeConfig {
                    draft = StreamConfigurationDraft(config: config)
                } else {
                    draft.rtmpURL = getUserDefault(forKey: "rtmpURL") ?? ""
                    draft.streamKey = getUserDefault(forKey: "rtmpKey") ?? ""
                }
            }
        }
    }
}

/// 純值草稿不持有 UserDefaults；未驗證或未按保存時不產生持久化副作用。
struct StreamConfigurationDraft {
    var id: UUID?
    var name = "自訂"
    var rtmpURL = ""
    var streamKey = ""
    init() {}
    init(config: StreamConfig) {
        id = config.id; name = config.name
        rtmpURL = config.rtmpURL; streamKey = config.streamKey
    }
    /// 名稱／網址去除首尾空白，金鑰保留原字元，避免意外改變授權資料。
    var validatedConfig: StreamConfig? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = rtmpURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !streamKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URLComponents(string: endpoint),
              ["rtmp", "rtmps"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return StreamConfig(id: id ?? UUID(), name: name, rtmpURL: endpoint, streamKey: streamKey)
    }
}
