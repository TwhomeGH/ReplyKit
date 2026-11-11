import Foundation
import CoreFoundation

/// 版本化的 JSON 備份；只攜帶白名單偏好，並保留共享／主 App 儲存區的差異。
struct SettingsBackupDocument {
    let createdAt: Date
    let includesSecrets: Bool
    let shared: [String: Any]
    let standard: [String: Any]

    var count: Int { shared.count + standard.count }

    /// 匯出穩定排序的 JSON；複合設定仍是 JSON 物件，方便離線閱讀。
    func encoded() throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: [
            "format": "ReplyKit.settings", "version": 1,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
            "includesSecrets": includesSecrets,
            "shared": shared, "standard": standard
        ], options: [.prettyPrinted, .sortedKeys])
        guard data.count <= 2_097_152 else { throw SettingsBackupError.invalid("設定超過 2 MB") }
        return data
    }

    /// 匯入上限 2 MB；驗證完整檔案後才允許寫入任何偏好。
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2_097_152,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["format"] as? String == "ReplyKit.settings",
              let version = root["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let date = root["createdAt"] as? String,
              let createdAt = ISO8601DateFormatter().date(from: date),
              let secrets = root["includesSecrets"] as? NSNumber,
              CFGetTypeID(secrets) == CFBooleanGetTypeID(),
              let shared = root["shared"] as? [String: Any],
              let standard = root["standard"] as? [String: Any]
        else { throw SettingsBackupError.invalid("格式、版本或大小不符") }
        let result = Self(createdAt: createdAt, includesSecrets: secrets.boolValue,
                          shared: shared, standard: standard)
        try SettingsBackupRegistry.validate(result)
        return result
    }
}

/// 備份錯誤只描述欄位名稱，不將金鑰或設定值寫入日誌。
enum SettingsBackupError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let field): return "設定備份無法使用：\(field)"
        }
    }
}

/// 集中管理可搬移設定。新增偏好必須明確選擇儲存區、型別與敏感性。
enum SettingsBackupRegistry {
    enum Rule {
        case boolean, number(ClosedRange<Double>), integer(ClosedRange<Double>), text
        case jsonData, dictionary
    }

    static let secretShared: Set<String> = ["rtmpURL", "rtmpKey", "logURL"]
    static let secretStandard: Set<String> = ["streamConfigs", "activeStreamConfigID"]

    // 不包含 onlogPage、onAudioPage、PauseStream、ReplyKitWidth/Height 等執行狀態。
    static let shared: [String: Rule] = {
        var rules: [String: Rule] = [:]
        func add(_ keys: String, _ rule: Rule) {
            for key in keys.split(separator: " ") { rules[String(key)] = rule }
        }
        add("BacklogTime Enablelog EnableRotatelog EnableSocketlog EnableTimeDebug EnablePipelineLog PIPLog PIPChatLog PIPLayoutLog PIPFrameLog logAppBackground ChangeBit useEnhancedRTMP enableRTMPLog isNotifyChat RotateOriginal useBic isOringinAudio enableNoiseFix enableEchoFix enableAGCFix enableMetalAudio allowFrameReordering h264useCAVLC vtSpeedPriority isLowLatencyRateControlEnabled pipPowerSaving pipHideSystemControls pipCompactOverlay pipNoticeAvatar avLagLongSessionSegments TTSEnabled TTSReadMainOnly TTSReadUserName TTSInterruptCurrent screenStreamRotateLeft directRecordingEnabled directRecordingAutomaticBitrate recordingCanvasFill recordingAutoMerge recordingCompress recordingCompressionSystemQuality recordingCompressionMultiPass", .boolean)
        add("AppLanguage externalLogTransport profileName PIPNowTimeLabelOverride PIPLiveLabelOverride PIPEndedLabelOverride pipSecondaryMode pipMainTextColor pipSecondaryTextColor avLagPersistenceMode TTSReadMiddleName TTSLanguage TTSVoiceIdentifier captureBackend captureWorkMode recordingOrientationPolicy recordingVideoCodec streamFramePolicy videoScalingMode directRecordingCodec recordingCanvasMode recordingCompressionCodec h264level videoCodec hevcLevel streamAudioBitrate rtmpURL rtmpKey logURL", .text)
        add("dstW dstH odstW odstH recordingCanvasWidth recordingCanvasHeight directRecordingEdge recordingCompressionEdge", .integer(0...16384))
        add("avLagSegmentHours", .integer(1...8))
        add("bitRate", .integer(100_000...200_000_000))
        add("KeyFrameInterval", .integer(0...60))
        add("BitRateMode logMode", .integer(0...2))
        add("BufferCount", .integer(-1...1000))
        add("screenCaptureKitVideoBufferMB replayKitVideoBufferMB", .integer(8...64))
        add("screenCaptureKitVideoBufferDurationMS replayKitVideoBufferDurationMS", .integer(50...500))
        add("Rotate LOrientation", .integer(0...360))
        add("socketListenPort", .integer(1...65535))
        add("directRecordingFPS recordingCompressionFPS", .integer(0...240))
        add("directRecordingMbps recordingCompressionMbps", .integer(1...200))
        add("recordingSegmentSeconds", .integer(0...86400))
        add("PIPFontMain PIPFontSecond PIPAdOverlayFont PIPAdOverlayUserFont", .number(1...200))
        add("PIPAdOverlaySpacing", .number(0...100))
        add("PIPAdOverlayDuration", .number(0...3600))
        // 沿用現有設定頁允許的範圍；不能讓合法舊偏好阻止整份備份。
        add("fadeAlpha fadeTime scrollTime", .number(0...100))
        add("pipClockSeconds pipKeepaliveSeconds", .number(1...60))
        add("appVolume micVolume TTSRate TTSVolume", .number(0...1))
        add("appAddVolume micAddVolume", .number(0...100))
        add("TTSPitch", .number(0.5...2))
        add("TTSMinLength TTSMaxLength TTSMaxQueueSize", .integer(0...100000))
        add("TTSQueueOverflowAction", .integer(0...2))
        add("OverlaySceneConfig", .jsonData)
        return rules
    }()

    static let standard: [String: Rule] = [
        "liveActivityEnabled": .boolean, "liveActivityInterval": .integer(60...900),
        "gpuConfigs": .jsonData, "gpuConfigsSelect": .jsonData,
        "SpeechFilterSettings": .dictionary,
        "streamConfigs": .jsonData, "activeStreamConfigID": .text,
        "rtmpUserPresets": .jsonData
    ]

    /// 擷取已保存的值；沒有設定的鍵不創造預設值，還原時採合併而非清空整個 domain。
    static func capture(shared defaults: UserDefaults, standard local: UserDefaults,
                        includesSecrets: Bool) throws -> SettingsBackupDocument {
        func values(_ source: UserDefaults, _ rules: [String: Rule], _ secrets: Set<String>) throws -> [String: Any] {
            var result: [String: Any] = [:]
            for (key, rule) in rules where includesSecrets || !secrets.contains(key) {
                guard let value = source.object(forKey: key) else { continue }
                if case .jsonData = rule {
                    guard let data = value as? Data else { throw SettingsBackupError.invalid(key) }
                    result[key] = try JSONSerialization.jsonObject(with: data)
                } else { result[key] = value }
            }
            return result
        }
        let document = SettingsBackupDocument(createdAt: Date(), includesSecrets: includesSecrets,
            shared: try values(defaults, shared, secretShared),
            standard: try values(local, standard, secretStandard))
        try validate(document)
        return document
    }

    /// 未知鍵、錯誤型別或越界值一律拒絕，不部分套用不明版本的配置。
    static func validate(_ document: SettingsBackupDocument) throws {
        for (values, rules, secrets) in [(document.shared, shared, secretShared),
                                        (document.standard, standard, secretStandard)] {
            for (key, value) in values {
                guard let rule = rules[key], document.includesSecrets || !secrets.contains(key) else {
                    throw SettingsBackupError.invalid(key)
                }
                let valid: Bool
                switch rule {
                case .boolean:
                    valid = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
                case .number(let range), .integer(let range):
                    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                        let n = number.doubleValue
                        let whole: Bool
                        if case .integer = rule { whole = n.rounded() == n } else { whole = true }
                        valid = n.isFinite && range.contains(n) && whole
                    } else { valid = false }
                case .text: valid = (value as? String).map { $0.utf8.count <= 16384 } ?? false
                case .jsonData, .dictionary:
                    valid = JSONSerialization.isValidJSONObject(value)
                }
                guard valid else { throw SettingsBackupError.invalid(key) }
                try validateComplex(key: key, value: value)
            }
        }
    }

    /// 複合偏好需符合既有模型，不能只驗證它是合法 JSON。
    private static func validateComplex(key: String, value: Any) throws {
        switch key {
        case "gpuConfigs", "gpuConfigsSelect", "OverlaySceneConfig", "streamConfigs":
            let data = try JSONSerialization.data(withJSONObject: value)
            let decoder = JSONDecoder()
            switch key {
            case "gpuConfigs":
                let configs = try decoder.decode([GPUOutputConfig].self, from: data)
                guard configs.count <= 1000 else { throw SettingsBackupError.invalid(key) }
                for config in configs { try validateCanvas(config) }
            case "gpuConfigsSelect":
                try validateCanvas(decoder.decode(GPUOutputConfig.self, from: data))
            case "OverlaySceneConfig":
                let config = try decoder.decode(OverlaySceneConfig.self, from: data)
                let time = config.time
                guard config.version == 1, (1...200).contains(time.fontSize),
                      (0...1).contains(time.backgroundOpacity),
                      [time.marginX, time.marginY, time.offsetX, time.offsetY,
                       time.cornerRadius, time.paddingX, time.paddingY].allSatisfy({ $0.isFinite && abs($0) <= 16384 })
                else { throw SettingsBackupError.invalid(key) }
            default:
                let configs = try decoder.decode([StreamConfig].self, from: data)
                guard configs.count <= 1000, Set(configs.map(\.id)).count == configs.count else {
                    throw SettingsBackupError.invalid(key)
                }
            }
        case "SpeechFilterSettings":
            guard let dict = value as? [String: Any],
                  dict["blockKeywords"] is [String], dict["replaceKeywords"] is [String: String],
                  dict["removeURLs"] is Bool, dict["removeEmoji"] is Bool,
                  dict["removePureNumbers"] is Bool else { throw SettingsBackupError.invalid(key) }
            for field in ["replacementOrder", "disabledBlockKeywords", "disabledReplacementKeywords"] {
                if let stored = dict[field], !(stored is [String]) { throw SettingsBackupError.invalid(key) }
            }
        default: break
        }
    }

    /// 防止可解碼但不合理的畫布尺寸在還原後造成巨量資源配置。
    private static func validateCanvas(_ config: GPUOutputConfig) throws {
        guard [config.width, config.height, config.owidth, config.oheight].allSatisfy({ (0...16384).contains($0) }) else {
            throw SettingsBackupError.invalid("GPU 畫布尺寸")
        }
    }

    /// 僅於程序啟動、服務讀取偏好前套用。沒有出現在備份的鍵保持原值。
    static func apply(_ document: SettingsBackupDocument, shared defaults: UserDefaults,
                      standard local: UserDefaults) throws {
        try validate(document)
        // 先完成所有轉換，避免中途序列化失敗留下半套設定。
        func converted(_ values: [String: Any], _ rules: [String: Rule]) throws -> [String: Any] {
            try values.reduce(into: [String: Any]()) { result, entry in
                if case .jsonData? = rules[entry.key] {
                    result[entry.key] = try JSONSerialization.data(withJSONObject: entry.value, options: [.sortedKeys])
                } else { result[entry.key] = entry.value }
            }
        }
        let groupValues = try converted(document.shared, shared)
        let localValues = try converted(document.standard, standard)
        for (key, value) in groupValues { defaults.set(value, forKey: key) }
        for (key, value) in localValues { local.set(value, forKey: key) }
    }
}
