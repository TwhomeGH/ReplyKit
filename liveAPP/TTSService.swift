//
//  TTSService.swift
//  liveAPP
//
//  Created by Codex on 2026/5/18.
//

import AVFoundation
import Foundation

enum TTSQueueOverflowAction: Int {
    case skipNew = 0   // 跳過新訊息
    case stopOld = 1   // 停止目前朗讀，清空佇列
}

@MainActor
final class TTSService: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = TTSService()

    private let synthesizer = AVSpeechSynthesizer()
    #if os(iOS)
    private let callAudioKeeper = TTSCallAudioKeeper()
    private var audioSessionObservers: [NSObjectProtocol] = []
    #endif

    var isEnabled:Bool
    var minLen:Int = 3
    var readMainOnly:Bool = true
    var includeUser:Bool = true
    var maxLen:Int = 0

    var readMiddleName:String = ""

    //打斷
    var InterruptCurrent:Bool = true

    // 佇列控制
    var maxQueueSize: Int = 0   // 0 = 無限制
    var queueOverflowAction: TTSQueueOverflowAction = .skipNew
    private var pendingUtteranceCount = 0

    // 主語音配置
    var storedLanguage:String = ""
    var language:String = "zh-TW" 

    var storedVoiceIdentifier:String = ""
    var storedRate:Double =  0
    var storedPitch:Double =  0
    var storedVolume:Double =  0
    


    private var filter = SpeechFilterManager.shared

    func updateDefault() {

        isEnabled = userDefaults?.bool(forKey: "TTSEnabled") ?? false
        minLen = userDefaults?.integer(forKey: "TTSMinLength") ?? 3
        readMainOnly = (userDefaults?.object(forKey: "TTSReadMainOnly") as? Bool) ?? true

        includeUser = (userDefaults?.object(forKey: "TTSReadUserName") as? Bool) ?? true

        maxLen = userDefaults?.integer(forKey: "TTSMaxLength") ?? 0

        readMiddleName = userDefaults?.string(forKey:"TTSReadMiddleName") ?? ""

        InterruptCurrent = userDefaults?.bool(forKey: "TTSInterruptCurrent") ?? true

        maxQueueSize = max(0, userDefaults?.integer(forKey: "TTSMaxQueueSize") ?? 0)

        let rawAction = userDefaults?.integer(forKey: "TTSQueueOverflowAction") ?? 0
        queueOverflowAction = TTSQueueOverflowAction(rawValue: rawAction) ?? .skipNew

        storedLanguage = userDefaults?.string(forKey: "TTSLanguage") ?? ""

        language = storedLanguage.isEmpty ? "zh-TW" : storedLanguage

        storedVoiceIdentifier = userDefaults?.string(forKey: "TTSVoiceIdentifier") ?? ""
        storedRate = userDefaults?.double(forKey: "TTSRate") ?? 0
        storedPitch = userDefaults?.double(forKey: "TTSPitch") ?? 0
        storedVolume = userDefaults?.double(forKey: "TTSVolume") ?? 0

        sendlog(message:"已同步TTS設定")

    }
    func updateState(isON:Bool? = nil,min_Len:Int? = nil,MainOnly:Bool? = nil) {

        if let isON = isON {
            self.isEnabled = isON
        }

        if let min_Len = min_Len {
            self.minLen = min_Len
        }

        if let MainOnly = MainOnly {
            self.readMainOnly = MainOnly
        }

        // 待補齊其他設置 先預留用updateDefault一次更新


    }

    private override init() {

        // 部分初始化不能分離 應保留部分在此位置
        isEnabled = userDefaults?.bool(forKey: "TTSEnabled") ?? false
        minLen = userDefaults?.integer(forKey: "TTSMinLength") ?? 3
        readMainOnly = (userDefaults?.object(forKey: "TTSReadMainOnly") as? Bool) ?? true

        includeUser = (userDefaults?.object(forKey: "TTSReadUserName") as? Bool) ?? true

        maxLen = userDefaults?.integer(forKey: "TTSMaxLength") ?? 0

        readMiddleName = userDefaults?.string(forKey:"TTSReadMiddleName") ?? ""

        InterruptCurrent = userDefaults?.bool(forKey: "TTSInterruptCurrent") ?? true

        maxQueueSize = max(0, userDefaults?.integer(forKey: "TTSMaxQueueSize") ?? 0)

        let rawAction = userDefaults?.integer(forKey: "TTSQueueOverflowAction") ?? 0
        queueOverflowAction = TTSQueueOverflowAction(rawValue: rawAction) ?? .skipNew

        storedLanguage = userDefaults?.string(forKey: "TTSLanguage") ?? ""

        language = storedLanguage.isEmpty ? "zh-TW" : storedLanguage

        storedVoiceIdentifier = userDefaults?.string(forKey: "TTSVoiceIdentifier") ?? ""
        storedRate = userDefaults?.double(forKey: "TTSRate") ?? 0
        storedPitch = userDefaults?.double(forKey: "TTSPitch") ?? 0
        storedVolume = userDefaults?.double(forKey: "TTSVolume") ?? 0


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
        audioSessionObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { _ in
            Task { @MainActor in
                sendlog(message: "TTS: 音頻服務已丟失，等待重置")
            }
        })
        #endif
    }

    deinit {
        for observer in audioSessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        audioSessionObservers.removeAll()

        sendlog(message:"TTS釋放 清理觀察器使用")
    }


    
    

    func speakStreamMessage(
        user: String,
        message: String,
        isMain:Bool = true
    ) {
        guard isEnabled else { return }

        
        let RES_MSG = filter.processMessage(message)


        if RES_MSG.count < minLen {
            sendlog(message:"太短了跳過 少於\(minLen)個字")
            return;
        }


        if readMainOnly && !isMain {
            sendlog(message:"跳過次要訊息")
            return
        }

        let trimmedMessage = RES_MSG.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedMessage.isEmpty else { return }

        
        let storedMaxLength = maxLen
        let maxLength = storedMaxLength > 0 ? storedMaxLength : 120

        
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
        pendingUtteranceCount = 0
        sendlog(message: "TTSService.stop: 停止朗讀")
        callAudioKeeper.stop()
    }

    func refreshAudioSessionForCurrentSetting() {
        #if os(iOS)
        sendlog(message: "TTSService.refreshAudioSessionForCurrentSetting: isEnabled=\(isEnabled)")
        if isEnabled {
            callAudioKeeper.configureSessionOnly()
        } else {
            callAudioKeeper.stop()
        }
        #endif
    }

    func stopPersistentAudio() {
        #if os(iOS)
        sendlog(message: "TTSService.stopPersistentAudio")
        callAudioKeeper.stop()
        #endif
    }

    private func speak(_ text: String, keepsCallAudioAlive: Bool = true) {
        guard !text.isEmpty else { return }

        if InterruptCurrent,
            synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            pendingUtteranceCount = 0
        }

        // 佇列上限檢查
        if maxQueueSize > 0 && pendingUtteranceCount >= maxQueueSize {
            switch queueOverflowAction {
            case .skipNew:
                sendlog(message:"TTS 佇列已滿 (\(pendingUtteranceCount)/\(maxQueueSize))，跳過新訊息")
                return
            case .stopOld:
                sendlog(message:"TTS 佇列已滿 (\(pendingUtteranceCount)/\(maxQueueSize))，清空佇列")
                synthesizer.stopSpeaking(at: .immediate)
                pendingUtteranceCount = 0
            }
        }

        #if os(iOS)
        if keepsCallAudioAlive {
            callAudioKeeper.start()
        } else {
            callAudioKeeper.configureSessionOnly()
        }
        #endif


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

        pendingUtteranceCount += 1
        synthesizer.speak(utterance)
    }

    // MARK: - AVSpeechSynthesizerDelegate
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.pendingUtteranceCount = max(0, self.pendingUtteranceCount - 1)
            if self.pendingUtteranceCount == 0 {
                self.callAudioKeeper.stop()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.pendingUtteranceCount = max(0, self.pendingUtteranceCount - 1)
            if self.pendingUtteranceCount == 0 {
                self.callAudioKeeper.stop()
            }
        }
    }

    #if os(iOS)
    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        sendlog(message: "TTS interruption: type=\(type.rawValue)")
        if type == .ended {
            // Interruption ended — force reconfigure to reclaim session
            callAudioKeeper.forceReconfigure()
        }
    }

    private func handleMediaServicesReset(_ notification: Notification) {
        sendlog(message: "TTS mediaServicesWereReset: 音訊服務已重置")
        // Audio services were fully rebuilt — must force reconfigure
        callAudioKeeper.forceReconfigure()
    }
    #endif
}

#if os(iOS)
@MainActor
private final class TTSCallAudioKeeper {
    private var isActive = false
    private var isConfigured = false

    func configureSessionOnly() {
        guard !isConfigured else {
            sendlog(message: "TTS configureSessionOnly: 已配置過，跳過")
            return
        }
        sendlog(message: "TTS configureSessionOnly: 開始配置音訊會話")
        do {
            try configurePlaybackSession()
            isConfigured = true
            sendlog(message: "TTS configureSessionOnly: 配置成功")
        } catch {
            sendlog(message: "TTS configureSessionOnly: 配置失敗 \(error.localizedDescription)")
        }
    }

    func start() {
        guard !isActive else {
            sendlog(message: "TTS start: 已啟用，跳過")
            return
        }
        sendlog(message: "TTS start: 啟動音訊會話")
        configureSessionOnly()
        isActive = true
    }

    func stop() {
        guard isActive else {
            sendlog(message: "TTS stop: 未啟用，跳過")
            return
        }
        sendlog(message: "TTS stop: 停止音訊會話")
        isActive = false
    }

    func forceReconfigure() {
        sendlog(message: "TTS forceReconfigure: 強制重新配置")
        isConfigured = false
        configureSessionOnly()
    }

    private func configurePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playback,
            mode: .default,
            options: [
                .mixWithOthers,
                .allowAirPlay
            ]
        )
        try session.setActive(true)
    }
}
#endif
