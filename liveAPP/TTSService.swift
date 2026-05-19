//
//  TTSService.swift
//  liveAPP
//
//  Created by Codex on 2026/5/18.
//

import AVFoundation
import Foundation

final class TTSService: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = TTSService()

    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speakStreamMessage(
        user: String,
        message: String
    ) {
        guard userDefaults?.bool(forKey: "TTSEnabled") ?? false else { return }

        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }

        let includeUser = userDefaults?.bool(forKey: "TTSReadUserName") ?? true


        let storedMaxLength = userDefaults?.integer(forKey: "TTSMaxLength") ?? 0
        let maxLength = storedMaxLength > 0 ? storedMaxLength : 120

        // 中間詞
        let readMiddleName = userDefaults?.string(forKey:"TTSReadMiddleName") ?? ""

        // TTS 郎讀內容
        
        var text = includeUser && !user.isEmpty ? "\(user) \(readMiddleName) \(trimmedMessage)" : trimmedMessage


        if text.count > maxLength {
            text = String(text.prefix(maxLength))
        }

        DispatchQueue.main.async { [weak self] in
            self?.speak(text)
        }
    }

    func speakPreview() {
        speak("這是一段系統朗讀測試。")
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.synthesizer.isSpeaking {
                self.synthesizer.stopSpeaking(at: .immediate)
            }
        }
    }

    private func speak(_ text: String) {
        guard !text.isEmpty else { return }

        if userDefaults?.object(forKey: "TTSInterruptCurrent") as? Bool ?? true,
            synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            sendlog(message: "TTS音訊會話設定失敗: \(error.localizedDescription)")
        }
        #endif

        let storedLanguage = userDefaults?.string(forKey: "TTSLanguage") ?? ""
        let language = storedLanguage.isEmpty ? "zh-TW" : storedLanguage
        let storedRate = userDefaults?.double(forKey: "TTSRate") ?? 0
        let storedPitch = userDefaults?.double(forKey: "TTSPitch") ?? 0
        let storedVolume = userDefaults?.double(forKey: "TTSVolume") ?? 0

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = Float(storedRate > 0 ? storedRate : Double(AVSpeechUtteranceDefaultSpeechRate))
        utterance.pitchMultiplier = Float(storedPitch > 0 ? storedPitch : 1.0)
        utterance.volume = Float(storedVolume > 0 ? storedVolume : 1.0)

        synthesizer.speak(utterance)
    }
}
