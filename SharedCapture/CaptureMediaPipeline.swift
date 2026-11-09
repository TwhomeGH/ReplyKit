import HaishinKit

/// 兩種擷取來源共用 Mixer 建立與音訊軌道慣例。影音來源的轉換留在各自轉接層。
final class CaptureMediaPipeline: Sendable {
    let mixer = MediaMixer(captureSessionMode: .manual, multiTrackAudioMixingEnabled: true)
    static func audioSettings(from original: AudioMixerSettings, microphone: Bool) -> AudioMixerSettings {
        var settings = original
        settings.tracks[0] = .default
        if microphone { settings.tracks[1] = .default }
        else { settings.tracks.removeValue(forKey: 1) }
        // 混音時鐘選「目前有持續資料」的軌：mic 開啟時用 mic，避免 App 軌
        // 靜默但仍有 callback 時把 mic 當成非主軌反覆 align／丟樣本；mic 關閉
        // 或中途停止時，HaishinKit 的 activeClockTrack 會 fallback 到 App 軌。
        // 輸出格式仍固定取自 App 軌，保留立體聲，不因時鐘切到 mic 而變 mono。
        settings.mainTrack = microphone ? 1 : 0
        settings.outputFormatTrack = 0
        return settings
    }
}
