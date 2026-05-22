//
//  TTSService.swift
//  liveAPP
//
//  Created by Codex on 2026/5/18.
//

import AVFoundation
import Foundation

@MainActor
final class TTSService: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = TTSService()

    private let synthesizer = AVSpeechSynthesizer()
    #if os(iOS)
    private let callAudioKeeper = TTSCallAudioKeeper()
    private var audioSessionObservers: [NSObjectProtocol] = []
    #endif

    private override init() {
        super.init()
        synthesizer.delegate = self
        #if os(iOS)
        audioSessionObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                self.handleAudioSessionInterruption(notification)
            }
        })
        audioSessionObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                self.handleMediaServicesReset(notification)
            }
        })
        #endif
    }

    private var filter = SpeechFilterManager.shared
    

    func speakStreamMessage(
        user: String,
        message: String,
        isMain:Bool = true
    ) {
        guard userDefaults?.bool(forKey: "TTSEnabled") ?? false else { return }

        let minLen = userDefaults?.integer(forKey: "TTSMinLength") ?? 3


        let RES_MSG = filter.processMessage(message)


        if RES_MSG.count < minLen {
            sendlog(message:"太短了跳過 少於\(minLen)個字")
            return;
        }


        if (userDefaults?.bool(forKey: "TTSReadMainOnly") ?? true) && !isMain {
            sendlog(message:"跳過次要訊息")
            return
        }

        let trimmedMessage = RES_MSG.trimmingCharacters(in: .whitespacesAndNewlines)

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

        speak(text)
    }

    func speakPreview() {
        speak("這是一段系統朗讀測試。", keepsCallAudioAlive: false)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    func refreshAudioSessionForCurrentSetting() {
        #if os(iOS)
        if userDefaults?.bool(forKey: "TTSEnabled") ?? false {
            callAudioKeeper.start()
        } else {
            callAudioKeeper.stop()
        }
        #endif
    }

    func stopPersistentAudio() {
        #if os(iOS)
        callAudioKeeper.stop()
        #endif
    }

    private func speak(_ text: String, keepsCallAudioAlive: Bool = true) {
        guard !text.isEmpty else { return }

        if userDefaults?.object(forKey: "TTSInterruptCurrent") as? Bool ?? true,
            synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        #if os(iOS)
        if keepsCallAudioAlive {
            callAudioKeeper.start()
        } else {
            callAudioKeeper.configureSessionOnly()
        }
        #endif

        let storedLanguage = userDefaults?.string(forKey: "TTSLanguage") ?? ""
        let language = storedLanguage.isEmpty ? "zh-TW" : storedLanguage
        let storedVoiceIdentifier = userDefaults?.string(forKey: "TTSVoiceIdentifier") ?? ""
        let storedRate = userDefaults?.double(forKey: "TTSRate") ?? 0
        let storedPitch = userDefaults?.double(forKey: "TTSPitch") ?? 0
        let storedVolume = userDefaults?.double(forKey: "TTSVolume") ?? 0

        let utterance = AVSpeechUtterance(string: text)
        if !storedVoiceIdentifier.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: storedVoiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: language)
        }
        utterance.rate = Float(storedRate > 0 ? storedRate : Double(AVSpeechUtteranceDefaultSpeechRate))
        utterance.pitchMultiplier = Float(storedPitch > 0 ? storedPitch : 1.0)
        utterance.volume = Float(storedVolume > 0 ? storedVolume : 1.0)

        synthesizer.speak(utterance)
    }

    #if os(iOS)
    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType),
            type == .ended
        else { return }

        refreshAudioSessionForCurrentSetting()
    }

    private func handleMediaServicesReset(_ notification: Notification) {
        refreshAudioSessionForCurrentSetting()
    }
    #endif
}

#if os(iOS)
@MainActor
private final class TTSCallAudioKeeper {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var isKeepingAlive = false

    func configureSessionOnly() {
        do {
            try configureCallSession()
        } catch {
            sendlog(message: "TTS通話音訊會話設定失敗: \(error.localizedDescription)")
        }
    }

    func start() {
        configureSessionOnly()

        if sourceNode == nil {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
            guard let format else {
                sendlog(message: "TTS通話音訊格式建立失敗")
                return
            }

            var phase = 0.0
            let amplitude = 0.00001
            let theta = 2.0 * Double.pi * 18.0 / format.sampleRate
            let node = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for frame in 0..<Int(frameCount) {
                    let sample = Float(sin(phase) * amplitude)
                    phase += theta
                    if phase > 2.0 * Double.pi {
                        phase -= 2.0 * Double.pi
                    }

                    for buffer in buffers {
                        guard let data = buffer.mData else { continue }
                        data.assumingMemoryBound(to: Float.self)[frame] = sample
                    }
                }
                return noErr
            }

            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 1.0
            sourceNode = node
        }

        guard !engine.isRunning else {
            isKeepingAlive = true
            return
        }

        do {
            engine.prepare()
            try engine.start()
            isKeepingAlive = true
            sendlog(message: "TTS已啟用語音通話後台保活")
        } catch {
            isKeepingAlive = false
            sendlog(message: "TTS通話音訊引擎啟動失敗: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isKeepingAlive || engine.isRunning else { return }

        engine.stop()
        isKeepingAlive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        sendlog(message: "TTS已停止語音通話後台保活")
    }

    private func configureCallSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [
                .allowBluetoothHFP,
                .allowBluetoothA2DP
            ]
        )
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
    }
}
#endif
