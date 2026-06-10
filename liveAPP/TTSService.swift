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
        ) { [weak self] notification in
            guard let self else { return }
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
    }

    func refreshAudioSessionForCurrentSetting() {
        #if os(iOS)
        if  isEnabled {
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
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.pendingUtteranceCount = max(0, self.pendingUtteranceCount - 1)
        }
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
        guard !(isKeepingAlive && engine.isRunning) else { return }

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
