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
    
    private let defaultsKey = "SpeechFilterSettings"
    
    private init() {   // 私有化 init，避免外部建立新實例
        loadFromUserDefaults()
    }
    
    /// 處理訊息：刪除 URL、刪除或替換關鍵字
    func processMessage(_ message: String) -> String {
        var result = message
        
        // 1. 移除 URL
        if removeURLs {
            let urlPattern = #"https?:\/\/[^\s]+"#
            result = result.replacingOccurrences(of: urlPattern,
                                                 with: "",
                                                 options: .regularExpression)
        }
        
        // 2. 移除 blockKeywords
        for word in blockKeywords {
            result = result.replacingOccurrences(of: word, with: "")
        }
        
        // 3. 替換 replaceKeywords
        for (word, replacement) in replaceKeywords {
            result = result.replacingOccurrences(of: word, with: replacement)
        }
        
        return result
    }
    
    /// 儲存到 UserDefaults
    private func saveToUserDefaults() {
        let dict: [String: Any] = [
            "blockKeywords": blockKeywords,
            "replaceKeywords": replaceKeywords,
            "removeURLs": removeURLs
        ]
        UserDefaults.standard.set(dict, forKey: defaultsKey)
    }
    
    /// 從 UserDefaults 載入
    private func loadFromUserDefaults() {
        guard let dict = UserDefaults.standard.dictionary(forKey: defaultsKey) else { return }
        
        if let block = dict["blockKeywords"] as? [String] {
            blockKeywords = block
        }
        if let replace = dict["replaceKeywords"] as? [String: String] {
            replaceKeywords = replace
        }
        if let remove = dict["removeURLs"] as? Bool {
            removeURLs = remove
        }
    }
}


// MARK: TTS過濾頁
struct FilterSettingsView: View {
    @StateObject private var filter = SpeechFilterManager.shared
    
    @State private var inputText = ""
    @State private var newBlockWord = ""
    @State private var newReplaceWord = ""
    @State private var newReplacement = "B"
    @Environment(\.editMode) private var editMode   // 監聽編輯模式
    
    var processedText: String {
        filter.processMessage(inputText)
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
                    
                    // Block Keywords
                    VStack(alignment: .leading) {
                        Text("排除關鍵字")
                        HStack {
                            TextField("新增排除字", text: $newBlockWord)
                                .textFieldStyle(.roundedBorder)
                            Button("加入") {
                                if !newBlockWord.isEmpty {
                                    filter.blockKeywords.append(newBlockWord)
                                    newBlockWord = ""
                                }
                            }
                        }
                        List {
                            ForEach(filter.blockKeywords.indices, id: \.self) { index in
                                if editMode?.wrappedValue.isEditing == true {
                                    TextField("編輯字", text: $filter.blockKeywords[index])
                                } else {
                                    Text(filter.blockKeywords[index])
                                }
                            }
                            .onDelete { indexSet in
                                filter.blockKeywords.remove(atOffsets: indexSet)
                            }
                        }
                        .frame(minHeight: 120)
                    }
                    
                    // Replace Keywords
                    VStack(alignment: .leading) {
                        Text("替換關鍵字")
                        HStack {
                            TextField("原字", text: $newReplaceWord)
                                .textFieldStyle(.roundedBorder)
                            TextField("替換字", text: $newReplacement)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Button("加入") {
                                if !newReplaceWord.isEmpty {
                                    filter.replaceKeywords[newReplaceWord] = newReplacement
                                    newReplaceWord = ""
                                    newReplacement = "B"
                                }
                            }
                        }
                        List {
                            ForEach(filter.replaceKeywords.keys.sorted(), id: \.self) { key in
                                if editMode?.wrappedValue.isEditing == true {
                                    HStack {
                                        TextField("原字", text: Binding(
                                            get: { key },
                                            set: { newKey in
                                                let value = filter.replaceKeywords[key] ?? ""
                                                filter.replaceKeywords.removeValue(forKey: key)
                                                filter.replaceKeywords[newKey] = value
                                            }
                                        ))
                                        Spacer()
                                        TextField("替換字", text: Binding(
                                            get: { filter.replaceKeywords[key] ?? "" },
                                            set: { newValue in
                                                filter.replaceKeywords[key] = newValue
                                            }
                                        ))
                                        .foregroundColor(.blue)
                                    }
                                } else {
                                    HStack {
                                        Text(key)
                                        Spacer()
                                        Text("→ \(filter.replaceKeywords[key] ?? "")")
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                            .onDelete { indexSet in
                                let keys = filter.replaceKeywords.keys.sorted()
                                for index in indexSet {
                                    let key = keys[index]
                                    filter.replaceKeywords.removeValue(forKey: key)
                                }
                            }
                        }
                        .frame(minHeight: 120)
                    }
                }
                .padding()
            }
            .navigationTitle("過濾器設定")
            .toolbar {
                EditButton() // 切換編輯模式
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
            TTSService.shared.refreshAudioSessionForCurrentSetting()
            if voiceOptions.isEmpty {
                voiceOptions = TTSVoiceOption.available
            }
        }
        .onDisappear {
            saveMiddleNameDraft()
            saveVoiceControlDrafts()
        }
    }
}
