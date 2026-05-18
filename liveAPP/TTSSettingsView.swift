//
//  TTSSettingsView.swift
//  liveAPP
//
//  Created by Codex on 2026/5/18.
//

import AVFoundation
import SwiftUI

struct TTSSettingsView: View {
    @AppStorage("TTSEnabled", store: userDefaults) private var ttsEnabled = false
    @AppStorage("TTSReadUserName", store: userDefaults) private var readUserName = true
    @AppStorage("TTSReadGiftMessage", store: userDefaults) private var readGiftMessage = false
    @AppStorage("TTSInterruptCurrent", store: userDefaults) private var interruptCurrent = true
    @AppStorage("TTSLanguage", store: userDefaults) private var language = "zh-TW"
    @AppStorage("TTSRate", store: userDefaults) private var rate = Double(AVSpeechUtteranceDefaultSpeechRate)
    @AppStorage("TTSPitch", store: userDefaults) private var pitch = 1.0
    @AppStorage("TTSVolume", store: userDefaults) private var volume = 1.0
    @AppStorage("TTSMaxLength", store: userDefaults) private var maxLength = 120

    private let languageOptions = [
        ("zh-TW", "繁體中文"),
        ("zh-CN", "簡體中文"),
        ("ja-JP", "日文"),
        ("en-US", "英文")
    ]

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("朗讀開關")) {
                    Toggle(isOn: $ttsEnabled) {
                        Text("啟用聊天室TTS朗讀")
                    }
                    .onChange(of: ttsEnabled) { newValue in
                        if !newValue {
                            TTSService.shared.stop()
                        }
                        sendlog(message: "TTS朗讀開關: \(newValue)")
                    }

                    Toggle(isOn: $readUserName) {
                        Text("朗讀使用者名稱")
                    }

                    Toggle(isOn: $readGiftMessage) {
                        Text("朗讀禮物提示")
                    }

                    Toggle(isOn: $interruptCurrent) {
                        Text("新訊息打斷目前朗讀")
                    }
                }

                Section(header: Text("聲音")) {
                    Picker("朗讀語言", selection: $language) {
                        ForEach(languageOptions, id: \.0) { option in
                            Text(option.1).tag(option.0)
                        }
                    }

                    VStack(alignment: .leading) {
                        Text("語速: \(String(format: "%.2f", rate))")
                        Slider(value: $rate, in: 0.1...0.7, step: 0.01)
                    }

                    VStack(alignment: .leading) {
                        Text("音調: \(String(format: "%.1f", pitch))")
                        Slider(value: $pitch, in: 0.5...2.0, step: 0.1)
                    }

                    VStack(alignment: .leading) {
                        Text("音量: \(Int(volume * 100))%")
                        Slider(value: $volume, in: 0...1, step: 0.05)
                    }
                }

                Section(header: Text("訊息限制")) {
                    Stepper("最長朗讀字數: \(maxLength)", value: $maxLength, in: 20...500, step: 10)

                    Button("測試朗讀") {
                        TTSService.shared.speakPreview()
                    }

                    Button("停止朗讀") {
                        TTSService.shared.stop()
                    }
                }
            }
            .navigationTitle("TTS朗讀")
        }
    }
}
