import HaishinKit

/// 兩種擷取來源共用 Mixer 建立與音訊軌道慣例。影音來源的轉換留在各自轉接層。
final class CaptureMediaPipeline: Sendable {
    let mixer = MediaMixer(captureSessionMode: .manual, multiTrackAudioMixingEnabled: true)
    static func audioSettings(from original: AudioMixerSettings, microphone: Bool) -> AudioMixerSettings {
        var settings = original
        settings.tracks[0] = .default
        if microphone { settings.tracks[1] = .default }
        else { settings.tracks.removeValue(forKey: 1) }
        settings.mainTrack = microphone ? 1 : 0
        settings.outputFormatTrack = 0
        return settings
    }
}
