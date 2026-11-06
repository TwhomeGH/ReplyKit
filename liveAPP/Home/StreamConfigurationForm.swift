import ReplayKit
import SwiftUI
import Combine
import os
import Foundation
import UniformTypeIdentifiers

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
@MainActor
struct FormView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = StreamConfigManager()
    @StateObject private var presetStore = RTMPPresetStore()
    @State private var draft = StreamConfigurationDraft()
    @State private var loaded = false
    @State private var error: String?
    @State private var notice: String?
    @State private var showingSavePreset = false
    @State private var newPresetName = ""
    @State private var showingPresetImporter = false
    @State private var showingPresetExporter = false
    @State private var showingPresetManager = false
    @State private var presetExportDocument: RTMPPresetExportDocument?

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
                    Menu(AppLanguage.localized("preset.quickSelect")) {
                        if !presetStore.builtIn.isEmpty {
                            Section(AppLanguage.localized("preset.builtIn")) {
                                ForEach(presetStore.builtIn) { preset in
                                    Button(preset.name) { apply(preset) }
                                }
                            }
                        }
                        if !presetStore.userPresets.isEmpty {
                            Section(AppLanguage.localized("preset.mine")) {
                                ForEach(presetStore.userPresets) { preset in
                                    Button(preset.name) { apply(preset) }
                                }
                                Button(AppLanguage.localized("preset.manage")) {
                                    showingPresetManager = true
                                }
                            }
                        }
                        Divider()
                        Button(AppLanguage.localized("preset.saveCurrent")) { prepareSaveCurrent() }
                        Button(AppLanguage.localized("preset.import")) { showingPresetImporter = true }
                        Button(AppLanguage.localized("preset.export")) { prepareExport() }
                            .disabled(presetStore.userPresets.isEmpty)
                    }
                    if let notice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
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
            .fileImporter(isPresented: $showingPresetImporter,
                          allowedContentTypes: [.json]) { result in
                importPresets(result)
            }
            .fileExporter(isPresented: $showingPresetExporter,
                          document: presetExportDocument,
                          contentType: .json,
                          defaultFilename: "RTMPPresets") { result in
                switch result {
                case .success:
                    notice = AppLanguage.localized("preset.exported")
                case .failure(let error):
                    self.error = error.localizedDescription
                    notice = nil
                }
            }
            .sheet(isPresented: $showingPresetManager) {
                PresetManagementView(store: presetStore)
            }
            .alert(AppLanguage.localized("preset.saveTitle"), isPresented: $showingSavePreset) {
                TextField(AppLanguage.localized("preset.namePlaceholder"), text: $newPresetName)
                Button(AppLanguage.localized("preset.save")) { saveCurrentPreset() }
                Button(AppLanguage.localized("preset.cancel"), role: .cancel) {}
            } message: {
                Text(AppLanguage.localized("preset.saveMessage"))
            }
        }
    }

    private func apply(_ preset: RTMPPreset) {
        let oldHost = URLComponents(string: draft.rtmpURL)?.host?.lowercased()
        let newHost = URLComponents(string: preset.rtmpURL)?.host?.lowercased()
        draft.rtmpURL = preset.rtmpURL
        if oldHost != newHost {
            draft.streamKey = ""
            notice = AppLanguage.localized("preset.keyCleared")
        } else {
            notice = nil
        }
        error = nil
    }

    private func prepareSaveCurrent() {
        let endpoint = draft.rtmpURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: endpoint),
              ["rtmp", "rtmps"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty else {
            error = AppLanguage.localized("preset.invalidURL")
            notice = nil
            return
        }
        newPresetName = host
        showingSavePreset = true
    }

    private func saveCurrentPreset() {
        if presetStore.addUserPreset(name: newPresetName, rtmpURL: draft.rtmpURL) {
            notice = AppLanguage.localized("preset.saved")
            error = nil
        } else {
            error = AppLanguage.localized("preset.saveFailed")
            notice = nil
        }
    }

    private func importPresets(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let imported = presetStore.importPresets(from: data)
                notice = String(format: AppLanguage.localized("preset.importResult"),
                                imported.added, imported.skipped)
                error = nil
            } catch {
                self.error = error.localizedDescription
                notice = nil
            }
        case .failure(let error):
            self.error = error.localizedDescription
            notice = nil
        }
    }

    private func prepareExport() {
        guard let data = presetStore.exportData() else {
            notice = AppLanguage.localized("preset.exportEmpty")
            return
        }
        presetExportDocument = RTMPPresetExportDocument(data: data)
        showingPresetExporter = true
    }
}

/// 只匯出使用者樣本的 JSON；不包含任何串流金鑰。
struct RTMPPresetExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
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
