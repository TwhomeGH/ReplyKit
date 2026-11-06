import SwiftUI

/// 管理使用者樣本：點列編輯名稱／URL，左滑刪除；內建樣本不在此列。
struct PresetManagementView: View {
    @ObservedObject var store: RTMPPresetStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: RTMPPreset?

    var body: some View {
        NavigationStack {
            Group {
                if store.userPresets.isEmpty {
                    ContentUnavailableView(
                        AppLanguage.localized("preset.manager.title"),
                        systemImage: "bookmark.slash",
                        description: Text(AppLanguage.localized("preset.manager.empty")))
                } else {
                    List {
                        Section {
                            ForEach(store.userPresets) { preset in
                                Button { editing = preset } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(preset.name)
                                            .foregroundStyle(.primary)
                                        Text(preset.rtmpURL)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .swipeActions {
                                    Button(role: .destructive) {
                                        store.removeUserPreset(preset)
                                    } label: {
                                        Label(AppLanguage.localized("preset.delete"),
                                              systemImage: "trash")
                                    }
                                }
                            }
                        } footer: {
                            Text(AppLanguage.localized("preset.manager.hint"))
                        }
                    }
                }
            }
            .navigationTitle(AppLanguage.localized("preset.manager.title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLanguage.localized("preset.done")) { dismiss() }
                }
            }
            .sheet(item: $editing) { preset in
                PresetEditView(store: store, preset: preset)
            }
        }
    }
}

/// 只修改名稱與 RTMP 網址；id 不變，重複或無效值留在表單顯示錯誤。
struct PresetEditView: View {
    @ObservedObject var store: RTMPPresetStore
    let preset: RTMPPreset
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var rtmpURL: String
    @State private var error: String?

    init(store: RTMPPresetStore, preset: RTMPPreset) {
        self.store = store
        self.preset = preset
        _name = State(initialValue: preset.name)
        _rtmpURL = State(initialValue: preset.rtmpURL)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(AppLanguage.localized("preset.namePlaceholder"), text: $name)
                TextField(AppLanguage.localized("preset.urlPlaceholder"), text: $rtmpURL)
#if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
#endif
                    .autocorrectionDisabled(true)
                if let error {
                    Text(error).foregroundStyle(.red)
                }
                Text(AppLanguage.localized("preset.edit.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle(AppLanguage.localized("preset.edit.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLanguage.localized("preset.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLanguage.localized("preset.save")) { save() }
                }
            }
        }
    }

    private func save() {
        if store.updateUserPreset(id: preset.id, name: name, rtmpURL: rtmpURL) != nil {
            dismiss()
        } else {
            error = AppLanguage.localized("preset.updateFailed")
        }
    }
}
