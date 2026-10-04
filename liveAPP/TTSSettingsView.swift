//
//  TTSSettingsView.swift
//  liveAPP
//
//  Created by Codex on 2026/5/18.
//

import AVFoundation
import SwiftUI
import Foundation
import Combine
import UniformTypeIdentifiers

// MARK: TTS過濾管理器
class SpeechFilterManager: ObservableObject {
    static let shared = SpeechFilterManager()   // 全局共用單例
    
    @Published var blockKeywords: [String] = [] {
        didSet { saveToUserDefaults() }
    }
    @Published var replaceKeywords: [String: String] = [:] {
        didSet { saveToUserDefaults() }
    }
    @Published var removeURLs: Bool = true {
        didSet { saveToUserDefaults() }
    }
    @Published var removeEmoji: Bool = true {
        didSet { saveToUserDefaults() }
    }
    @Published var removePureNumbers: Bool = false {
        didSet { saveToUserDefaults() }
    }
    
    @Published var disabledBlockKeywords: Set<String> = [] { didSet { saveToUserDefaults() } }
    @Published var disabledReplacementKeywords: Set<String> = [] { didSet { saveToUserDefaults() } }
    @Published var replacementOrder: [String] = [] { didSet { saveToUserDefaults() } }
    private var loading = false
    var orderedReplacementKeys: [String] {
        var seen = Set<String>()
        return (replacementOrder + replaceKeywords.keys.sorted()).filter { replaceKeywords[$0] != nil && seen.insert($0).inserted }
    }
    var configuration: SpeechFilterConfiguration {
        var value = SpeechFilterConfiguration(blockKeywords: blockKeywords,
            replaceKeywords: orderedReplacementKeys.map { SpeechReplacement(word: $0, replacement: replaceKeywords[$0]!, enabled: !disabledReplacementKeywords.contains($0)) },
            removeURLs: removeURLs, removeEmoji: removeEmoji, removePureNumbers: removePureNumbers)
        value.disabledBlockKeywords = blockKeywords.filter { disabledBlockKeywords.contains($0) }
        return value
    }
    func apply(_ config: SpeechFilterConfiguration) throws {
        let value = try config.validated()
        loading = true
        blockKeywords = value.blockKeywords
        replaceKeywords = Dictionary(uniqueKeysWithValues: value.replaceKeywords.map { ($0.word, $0.replacement) })
        replacementOrder = value.replaceKeywords.map(\.word)
        disabledBlockKeywords = Set(value.disabledBlockKeywords)
        disabledReplacementKeywords = Set(value.replaceKeywords.filter { !$0.enabled }.map(\.word))
        if let flag = value.removeURLs { removeURLs = flag }
        if let flag = value.removeEmoji { removeEmoji = flag }
        if let flag = value.removePureNumbers { removePureNumbers = flag }
        loading = false
        saveToUserDefaults()
    }
    /// 完整驗證、成功備份後才套用；錯誤不得留下半套設定。
    func importConfiguration(_ incoming: SpeechFilterConfiguration, replace: Bool,
                             useIncomingConflicts: Bool, directory: URL) throws -> URL {
        let current = configuration
        let next = try replace ? incoming.validated() : current.merging(incoming, useIncomingConflicts: useIncomingConflicts)
        let backup = try current.write(to: directory, backup: true)
        try apply(next)
        return backup
    }
    private let defaultsKey = "SpeechFilterSettings"
    
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadFromUserDefaults()
    }
    
    /// 處理訊息：刪除 URL、表情符號、純數字、刪除或替換關鍵字
    func processMessage(_ message: String) -> String {
        var result = message
        
        // 1. 移除 URL
        if removeURLs {
            let urlPattern = #"https?:\/\/[^\s]+"#
            result = result.replacingOccurrences(of: urlPattern,
                                                 with: "",
                                                 options: .regularExpression)
        }
        
        // 2. 移除表情符號（使用 isEmojiPresentation 避免誤刪數字）
        if removeEmoji {
            result = String(result.unicodeScalars.filter { !$0.properties.isEmojiPresentation })
        }
        
        // 3. 移除純數字內容
        if removePureNumbers {
            let pureNumberPattern = #"(?<!\d)\d+(?!\d)"#
            result = result.replacingOccurrences(of: pureNumberPattern,
                                                 with: "",
                                                 options: .regularExpression)
        }
        
        // 4. 移除 blockKeywords
        for word in blockKeywords where !disabledBlockKeywords.contains(word) {
            result = result.replacingOccurrences(of: word, with: "")
        }
        
        // 5. 替換 replaceKeywords
        for word in orderedReplacementKeys where !disabledReplacementKeywords.contains(word) {
            result = result.replacingOccurrences(of: word, with: replaceKeywords[word] ?? "")
        }
        
        return result
    }
    
    /// 儲存到 UserDefaults
    private func saveToUserDefaults() {
        guard !loading else { return }
        let dict: [String: Any] = [
            "blockKeywords": blockKeywords,
            "replaceKeywords": replaceKeywords,
            "replacementOrder": orderedReplacementKeys,
            "disabledBlockKeywords": Array(disabledBlockKeywords),
            "disabledReplacementKeywords": Array(disabledReplacementKeywords),
            "removeURLs": removeURLs,
            "removeEmoji": removeEmoji,
            "removePureNumbers": removePureNumbers
        ]
        defaults.set(dict, forKey: defaultsKey)
    }
    
    /// 從 UserDefaults 載入
    private func loadFromUserDefaults() {
        loading = true
        defer { loading = false }
        guard let dict = defaults.dictionary(forKey: defaultsKey) else { return }
        
        replacementOrder = dict["replacementOrder"] as? [String] ?? []
        disabledBlockKeywords = Set(dict["disabledBlockKeywords"] as? [String] ?? [])
        disabledReplacementKeywords = Set(dict["disabledReplacementKeywords"] as? [String] ?? [])
        if let block = dict["blockKeywords"] as? [String] {
            blockKeywords = block
        }
        if let replace = dict["replaceKeywords"] as? [String: String] {
            replaceKeywords = replace
        }
        if let remove = dict["removeURLs"] as? Bool {
            removeURLs = remove
        }
        if let emoji = dict["removeEmoji"] as? Bool {
            removeEmoji = emoji
        }
        if let numbers = dict["removePureNumbers"] as? Bool {
            removePureNumbers = numbers
        }
    }
}


// MARK: TTS過濾頁
@MainActor struct FilterSettingsView: View {
    @StateObject private var filter = SpeechFilterManager.shared
    
    @State private var importing = false
    @State private var preview: SpeechFilterConfiguration?
    @State private var useIncomingConflicts = false
    @State private var notice: String?
    @State private var exportedURL: URL?
    @State private var inputText = ""
    @State private var newBlockWord = ""
    @State private var newReplaceWord = ""
    @State private var newReplacement = "B"
    @Environment(\.editMode) private var editMode
    @Environment(\.horizontalSizeClass) private var sizeClass
    
    var processedText: String {
        filter.processMessage(inputText)
    }
    
    var body: some View {
            Group {
                if sizeClass == .regular {
                    // iPad / 寬螢幕 → 左右分欄
                    HStack(spacing: 0) {
                        inputSection
                            .frame(maxWidth: .infinity)
                            .padding()
                        
                        Divider()
                        
                        listSection
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .navigationTitle("過濾器設定")
                } else {
                    // iPhone / 窄螢幕 → 上下排版
                    VStack(spacing: 0) {
                        inputSection
                            .padding()
                        
                        Divider()
                        
                        listSection
                            .padding()
                    }
                    .navigationTitle("過濾器設定")
                }
            }
            .toolbar { EditButton() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: SpeechFilterConfiguration.maximumBytes + 1) ?? Data()
                    preview = try SpeechFilterConfiguration.decode(data)
                    useIncomingConflicts = false
                } catch { notice = error.localizedDescription }
            }
            .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
                importPreview
            }
            .alert("過濾器配置", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("好") { notice = nil }
            } message: { Text(notice ?? "") }
        
    }
    
    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var importPreview: some View {
        NavigationStack {
            Form {
                if let incoming = preview {
                    Section("匯入內容") {
                        Text("排除字：\(incoming.blockKeywords.count) 條；替換字：\(incoming.replaceKeywords.count) 條")
                        Text("合併保留目前過濾開關；取代套用檔案內的開關，未提供的開關維持原值。")
                        Text("套用前會先在 Documents 自動備份；備份失敗不變更設定。")
                    }
                    let blockConflicts = filter.configuration.blockConflicts(with: incoming)
                    let conflicts = filter.configuration.conflicts(with: incoming)
                    if !blockConflicts.isEmpty {
                        Section("排除字狀態衝突（\(blockConflicts.count) 條）") {
                            ForEach(blockConflicts, id: \.self) { word in
                                Text("\(word)：目前\(filter.disabledBlockKeywords.contains(word) ? "停用" : "啟用") → 匯入\(incoming.disabledBlockKeywords.contains(word) ? "停用" : "啟用")")
                            }
                        }
                    }
                    if !blockConflicts.isEmpty || !conflicts.isEmpty {
                        Toggle("合併衝突時採用匯入內容與啟用狀態", isOn: $useIncomingConflicts)
                    }
                    if !conflicts.isEmpty {
                        Section("替換衝突（\(conflicts.count) 條）") {
                            ForEach(conflicts, id: \.self) { word in
                                VStack(alignment: .leading) {
                                    Text(word)
                                    Text("目前\(filter.disabledReplacementKeywords.contains(word) ? "停用" : "啟用")／匯入\((incoming.replaceKeywords.first(where: { $0.word == word })?.enabled ?? true) ? "啟用" : "停用")")
                                    Text("目前：\(filter.replaceKeywords[word] ?? "")")
                                    Text("匯入：\(incoming.replaceKeywords.first(where: { $0.word == word })?.replacement ?? "")")
                                }
                            }
                        }
                    }
                    Section {
                        Button("確認合併") { applyImport(incoming, replace: false) }
                        Button("確認取代目前清單", role: .destructive) { applyImport(incoming, replace: true) }
                    }
                }
            }
            .navigationTitle("預覽過濾配置")
            .toolbar { Button("取消") { preview = nil } }
        }
    }
    private func applyImport(_ incoming: SpeechFilterConfiguration, replace: Bool) {
        do {
            let backup = try filter.importConfiguration(incoming, replace: replace,
                useIncomingConflicts: useIncomingConflicts, directory: documentsDirectory)
            preview = nil
            notice = "已套用配置。原配置備份：\(backup.lastPathComponent)"
        } catch { preview = nil; notice = error.localizedDescription }
    }

    // 左邊：輸入區
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("匯入 JSON") { importing = true }
                Button("匯出目前配置") {
                    do {
                        let url = try filter.configuration.write(to: documentsDirectory)
                        exportedURL = url
                        notice = "已儲存至檔案分享目錄 Documents：\(url.lastPathComponent)"
                    } catch { notice = error.localizedDescription }
                }
            }
            if let url = exportedURL { ShareLink("分享最近匯出的配置", item: url) }
            Text("匯出與備份存放在與 log.txt 相同的 Documents 目錄。")
                .font(.caption).foregroundStyle(.secondary)
            Text("朗讀過濾設定")
                .font(.headline)
            
            TextField("輸入訊息測試", text: $inputText)
                .textFieldStyle(.roundedBorder)
            
            if !processedText.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("處理後訊息：")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    Text(processedText)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                }
            }
            
            Divider()
            
            Toggle("移除 URL", isOn: $filter.removeURLs)
            
            Toggle("移除表情符號 Emoji", isOn: $filter.removeEmoji)
            
            Toggle("移除純數字", isOn: $filter.removePureNumbers)
            
            VStack(alignment: .leading) {
                Text("排除關鍵字")
                HStack {
                    TextField("新增排除字", text: $newBlockWord)
                        .textFieldStyle(.roundedBorder)
                    Button("加入") {
                        if !newBlockWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !filter.blockKeywords.contains(newBlockWord) {
                            filter.blockKeywords.append(newBlockWord)
                            newBlockWord = ""
                        }
                    }
                }
            }
            
            VStack(alignment: .leading) {
                Text("替換關鍵字")
                HStack {
                    TextField("原字", text: $newReplaceWord)
                        .textFieldStyle(.roundedBorder)
                    TextField("替換字", text: $newReplacement)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Button("加入") {
                        if !newReplaceWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let isNew = filter.replaceKeywords[newReplaceWord] == nil
                            filter.replaceKeywords[newReplaceWord] = newReplacement
                            if isNew { filter.replacementOrder = filter.orderedReplacementKeys.filter { $0 != newReplaceWord } + [newReplaceWord] }
                            newReplaceWord = ""
                            newReplacement = "B"
                        }
                    }
                }
            }
        }
    }
    
    // 右邊：列表區
    private var listSection: some View {
    List {
        Section(header: Text("已加入的排除字").font(.headline)) {
            ForEach(filter.blockKeywords.indices, id: \.self) { index in
                HStack {
                    Toggle("啟用排除字 \(filter.blockKeywords[index])", isOn: Binding(
                        get: { !filter.disabledBlockKeywords.contains(filter.blockKeywords[index]) },
                        set: { enabled in
                            let word = filter.blockKeywords[index]
                            if enabled { filter.disabledBlockKeywords.remove(word) }
                            else { filter.disabledBlockKeywords.insert(word) }
                        }
                    )).labelsHidden()
                    if editMode?.wrappedValue.isEditing == true {
                        TextField("編輯字", text: Binding(
                            get: { filter.blockKeywords[index] },
                            set: { word in
                                guard !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                      !filter.blockKeywords.enumerated().contains(where: { $0.offset != index && $0.element == word }) else { return }
                                let old = filter.blockKeywords[index]
                                let disabled = filter.disabledBlockKeywords.remove(old) != nil
                                filter.blockKeywords[index] = word
                                if disabled { filter.disabledBlockKeywords.insert(word) }
                            }
                        )).textFieldStyle(.roundedBorder)
                    } else { Text(filter.blockKeywords[index]) }
                }
            }
            .onDelete { indexSet in
                for index in indexSet { filter.disabledBlockKeywords.remove(filter.blockKeywords[index]) }
                filter.blockKeywords.remove(atOffsets: indexSet)
            }
        }
        
        Section(header: Text("已加入的替換字").font(.headline)) {
            ForEach(filter.orderedReplacementKeys, id: \.self) { key in
                HStack {
                    Toggle("啟用替換字 \(key)", isOn: Binding(
                        get: { !filter.disabledReplacementKeywords.contains(key) },
                        set: { enabled in
                            if enabled { filter.disabledReplacementKeywords.remove(key) }
                            else { filter.disabledReplacementKeywords.insert(key) }
                        }
                    )).labelsHidden()
                    Text(key) // 原字顯示，不直接編輯
                    Spacer()
                    if editMode?.wrappedValue.isEditing == true {
                        TextField("替換字", text: Binding(
                            get: { filter.replaceKeywords[key] ?? "" },
                            set: { newValue in
                                filter.replaceKeywords[key] = newValue
                            }
                        ))
                        .foregroundColor(.blue)
                    } else {
                        Text("→ \(filter.replaceKeywords[key] ?? "")")
                            .foregroundColor(.blue)
                    }
                }
            }
            .onDelete { indexSet in
                let keys = filter.orderedReplacementKeys
                for index in indexSet {
                    let key = keys[index]
                    filter.disabledReplacementKeywords.remove(key)
                    filter.replaceKeywords.removeValue(forKey: key)
                }
            }
            .onMove { source, destination in
                var keys = filter.orderedReplacementKeys
                keys.move(fromOffsets: source, toOffset: destination)
                filter.replacementOrder = keys
            }
        }
    }
}

}








struct TTSVoiceOption: Identifiable {
    let id: String
    let language: String
    let name: String

    static var available: [TTSVoiceOption] {
        AVSpeechSynthesisVoice.speechVoices()
            .map {
                TTSVoiceOption(
                    id: $0.identifier,
                    language: $0.language,
                    name: $0.name
                )
            }
            .sorted {
                if $0.language == $1.language {
                    return $0.name < $1.name
                }
                return $0.language < $1.language
            }
    }
}

struct VoiceListView: View {
    private let groupedVoices = Dictionary(grouping: TTSVoiceOption.available, by: \.language)
        .sorted { $0.key < $1.key }
    
    var body: some View {
        NavigationView {
            List {
                ForEach(groupedVoices, id: \.key) { group in
                    Section(header: Text(group.key)) {
                        ForEach(group.value) { voice in
                            Text(voice.name)
                        }
                    }
                }
            }
            .navigationTitle("可用語音清單")
        }
    }
}


struct TTSSettingsView: View {

    @State private var showVoiceList = false
    @State private var middleNameDraft = ""
    @State private var middleNameSaveTask: Task<Void, Never>?
    @State private var rateDraft = Double(AVSpeechUtteranceDefaultSpeechRate)
    @State private var pitchDraft = 1.0
    @State private var volumeDraft = 1.0
    @State private var voiceOptions: [TTSVoiceOption] = []

    @AppStorage("TTSEnabled", store: userDefaults) private var ttsEnabled = false

    // ReadMainOnly 只念主訊息
    @AppStorage("TTSReadMainOnly",store:userDefaults) private var TTSReadMainOnly = true

    @AppStorage("TTSReadUserName", store: userDefaults) private var readUserName = true

    @AppStorage("TTSInterruptCurrent", store: userDefaults) private var interruptCurrent = false
    @AppStorage("TTSMaxQueueSize", store: userDefaults) private var maxQueueSize = 0
    @AppStorage("TTSQueueOverflowAction", store: userDefaults) private var queueOverflowAction = 0




    // 用戶名與訊息本身的中堅詞
    @AppStorage("TTSReadMiddleName",store:userDefaults) private var readMiddleName = "說"

    @AppStorage("TTSLanguage", store: userDefaults) private var language = "zh-TW"
    @AppStorage("TTSVoiceIdentifier", store: userDefaults) private var voiceIdentifier = ""
    @AppStorage("TTSRate", store: userDefaults) private var rate = Double(AVSpeechUtteranceDefaultSpeechRate)
    @AppStorage("TTSPitch", store: userDefaults) private var pitch = 1.0
    @AppStorage("TTSVolume", store: userDefaults) private var volume = 1.0
    @AppStorage("TTSMaxLength", store: userDefaults) private var maxLength = 120
    @AppStorage("TTSMinLength", store: userDefaults) private var minLength = 3

    //@State private var Cache_MaxLength = 100
    let options = Array(stride(from: 5, through: 500, by: 5))

    let min_options = Array(stride(from:1, through: 500, by: 1))


    private var groupedVoiceOptions: [(key: String, value: [TTSVoiceOption])] {
        Dictionary(grouping: voiceOptions, by: \.language)
            .sorted { $0.key < $1.key }
    }

    private func saveMiddleNameDraft() {
        middleNameSaveTask?.cancel()
        if readMiddleName != middleNameDraft {
            readMiddleName = middleNameDraft
        }
    }

    private func scheduleMiddleNameSave(_ value: String) {
        middleNameSaveTask?.cancel()
        middleNameSaveTask = Task { [value] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                userDefaults?.set(value, forKey: "TTSReadMiddleName")
            }
        }
    }

    private func saveVoiceControlDrafts() {
        if rate != rateDraft {
            rate = rateDraft
        }
        if pitch != pitchDraft {
            pitch = pitchDraft
        }
        if volume != volumeDraft {
            volume = volumeDraft
        }
    }


    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("朗讀開關") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: $ttsEnabled) {
                                Text("啟用聊天室TTS朗讀")
                            }
                            .onChange(of: ttsEnabled) { newValue in
                                if newValue {
                                    TTSService.shared.refreshAudioSessionForCurrentSetting()
                                } else {
                                    TTSService.shared.stop()
                                    TTSService.shared.stopPersistentAudio()
                                }
                                sendlog(message: "TTS朗讀開關: \(newValue)")
                            }

                            Toggle(isOn: $TTSReadMainOnly) {
                                Text("只朗讀主訊息 OnlyMain MSG")
                            }


                            Toggle(isOn: $readUserName) {
                                Text("朗讀使用者名稱 Read User Name")
                            }

                            Text("中間詞輸入框 ReadMiddleName")
                                .font(.headline)

                            TextField("請輸入你要在用戶與訊息之間的詞...", text: $middleNameDraft)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .frame(maxWidth: .infinity)
                                .onSubmit {
                                    saveMiddleNameDraft()
                                }
                                .onChange(of: middleNameDraft) { newValue in
                                    scheduleMiddleNameSave(newValue)
                                }

                            Toggle(isOn: $interruptCurrent) {
                                Text("新訊息打斷目前朗讀")
                            }

                            Button("列出可用語言清單") {
                                showVoiceList = true
                            }
                            .sheet(isPresented: $showVoiceList) {
                                VoiceListView()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    GroupBox("聲音") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("朗讀語音", selection: $voiceIdentifier) {
                                Text("系統預設（\(language)）").tag("")
                                ForEach(groupedVoiceOptions, id: \.key) { group in
                                    Section(header: Text(group.key)) {
                                        ForEach(group.value) { option in
                                            Text(option.name).tag(option.id)
                                        }
                                    }
                                }
                            }
                            .onChange(of: voiceIdentifier) { newValue in
                                guard let voice = AVSpeechSynthesisVoice(identifier: newValue) else { return }
                                language = voice.language
                            }

                            VStack(alignment: .leading) {
                                Text("語速: \(String(format: "%.2f", rateDraft))")
                                Slider(
                                    value: $rateDraft,
                                    in: 0.1...0.7,
                                    onEditingChanged: { editing in
                                        if !editing {
                                            saveVoiceControlDrafts()
                                        }
                                    }
                                )
                            }

                            VStack(alignment: .leading) {
                                Text("音調: \(String(format: "%.1f", pitchDraft))")
                                Slider(
                                    value: $pitchDraft,
                                    in: 0.5...2.0,
                                    onEditingChanged: { editing in
                                        if !editing {
                                            saveVoiceControlDrafts()
                                        }
                                    }
                                )
                            }

                            VStack(alignment: .leading) {
                                Text("音量: \(Int(volumeDraft * 100))%")
                                Slider(
                                    value: $volumeDraft,
                                    in: 0...1,
                                    onEditingChanged: { editing in
                                        if !editing {
                                            saveVoiceControlDrafts()
                                        }
                                    }
                                )
                            }

                            Button("套用設定") {
                                saveMiddleNameDraft()
                                saveVoiceControlDrafts()
                                TTSService.shared.updateDefault()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    GroupBox("訊息限制") {
                        VStack(alignment: .leading, spacing: 12) {
                            
                            HStack {
                                Text("目前選擇最大字數：")
                                    Picker("", selection: $maxLength) {
                                        ForEach(options, id: \.self) { value in
                                            Text("\(value)").tag(value)
                                        }
                                    }
                                    .pickerStyle(.menu) // 滾輪選單
                            }

                            HStack {
                                Text("語音播報要求最小字數：")

                                Picker("", selection: $minLength) {
                                    ForEach(min_options, id: \.self) { value in
                                        Text("\(value)").tag(value)
                                    }
                                }
                                .pickerStyle(.menu) // 滾輪選單

                            }

                            HStack {
                                Text("佇列上限：")
                                Picker("", selection: $maxQueueSize) {
                                    Text("無限制").tag(0)
                                    Text("5").tag(5)
                                    Text("10").tag(10)
                                    Text("20").tag(20)
                                    Text("50").tag(50)
                                }
                                .pickerStyle(.menu)
                            }

                            HStack {
                                Text("佇列滿載：")
                                Picker("", selection: $queueOverflowAction) {
                                    Text("跳過新訊息").tag(0)
                                    Text("停止舊的，讀新的先").tag(1)
                                    Text("清空待朗讀").tag(2)
                                }
                                .pickerStyle(.menu)
                            }
                            .disabled(maxQueueSize == 0)

                            Button("測試朗讀") {
                                TTSService.shared.speakPreview()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Button("停止朗讀") {
                                TTSService.shared.stop()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            NavigationLink("TTS過濾詞管理") {
                                FilterSettingsView()
                            }

                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("TTS朗讀")
        }
        .navigationViewStyle(.stack)
        .onAppear {
            middleNameDraft = readMiddleName
            rateDraft = rate
            pitchDraft = pitch
            volumeDraft = volume
            if voiceOptions.isEmpty {
                voiceOptions = TTSVoiceOption.available
            }
        }
        .onDisappear {
            saveMiddleNameDraft()
            saveVoiceControlDrafts()

            TTSService.shared.updateDefault()
        }
    }
}
