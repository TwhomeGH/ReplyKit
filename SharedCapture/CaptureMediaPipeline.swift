import HaishinKit

/// 兩種擷取來源共用 Mixer 建立與音訊軌道慣例。影音來源的轉換留在各自轉接層。
final class CaptureMediaPipeline: Sendable {
    let mixer = MediaMixer(captureSessionMode: .manual, multiTrackAudioMixingEnabled: true)
    static func audioSettings(from original: AudioMixerSettings, microphone: Bool) -> AudioMixerSettings {
        var settings = original
        settings.tracks[0] = .default
        if microphone { settings.tracks[1] = .default }
        else { settings.tracks.removeValue(forKey: 1) }
        // App 軌是主要輸出與混音時鐘；mic 只作為另一軌參與混音。若 mic 被關閉或
        // 不再送資料，mainTrack 指向 mic 會讓 App 軌被當成非主軌對齊而失去輸出。
        settings.mainTrack = 0
        settings.outputFormatTrack = 0
        return settings
    }
}
