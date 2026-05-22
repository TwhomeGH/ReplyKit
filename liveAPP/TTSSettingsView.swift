//
//  TTSSettingsView.swift
//  liveAPP
//
//  Created by Codex on 2026/5/18.
//

import AVFoundation
import SwiftUI


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
                            
                            Text("目前選擇最大字數：\(maxLength)")

                            Picker("最長朗讀字數", selection: $maxLength) {
                                ForEach(options, id: \.self) { value in
                                    Text("\(value)").tag(value)
                                }
                            }
                            .pickerStyle(.menu) // 滾輪選單
                            
                            Text("語音播報要求最小字數：\(minLength)")

                            Picker("最小朗讀字數", selection: $minLength) {
                                ForEach(min_options, id: \.self) { value in
                                    Text("\(value)").tag(value)
                                }
                            }
                            .pickerStyle(.menu) // 滾輪選單


                            Button("測試朗讀") {
                                TTSService.shared.speakPreview()
                            }

                            Button("停止朗讀") {
                                TTSService.shared.stop()
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
