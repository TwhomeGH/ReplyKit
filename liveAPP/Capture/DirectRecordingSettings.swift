#if os(iOS)
import Foundation
import SwiftUI

/// 開錄固定的直接編碼設定，與系統錄製及錄後壓縮分開。
struct DirectRecordingSettings: Sendable {
    /// 沿用編碼、Mbps、尺寸與 FPS 欄位；此路徑不執行錄後轉碼。
    let encoding: RecordingCompressionSettings
    /// true 時不傳 AVVideoAverageBitRateKey，交由編碼器選擇。
    let automaticBitrate: Bool
    /// 每段目標秒數；以第一個超過邊界的視訊樣本切段。
    let segmentSeconds: Double
    /// 讀取開錄設定；預設 HEVC、8 Mbps、最長邊 1920、60 FPS、120 秒分段。
    /// - Parameter defaults: 錄製偏好來源；不合法的分段秒數回退為 120。
    init(defaults: UserDefaults) {
        automaticBitrate = defaults.bool(forKey: "directRecordingAutomaticBitrate")
        encoding = RecordingCompressionSettings(enabled: true,
            hevc: defaults.string(forKey: "directRecordingCodec") != "h264",
            megabits: defaults.object(forKey: "directRecordingMbps") as? Int ?? 8,
            longestEdge: defaults.object(forKey: "directRecordingEdge") as? Int ?? 1920,
            fpsLimit: defaults.object(forKey: "directRecordingFPS") as? Int ?? 60)
        let seconds = defaults.object(forKey: "recordingSegmentSeconds") as? Int ?? 120
        segmentSeconds = Double([60, 120, 300, 600].contains(seconds) ? seconds : 120)
    }
}

/// 可控錄製偏好入口；編碼與分段設定在下次開錄讀取。
struct DirectRecordingSettingsView: View {
    @AppStorage("directRecordingEnabled", store: userDefaults) private var enabled = false
    @AppStorage("directRecordingCodec", store: userDefaults) private var codec = "hevc"
    @AppStorage("directRecordingAutomaticBitrate", store: userDefaults) private var automaticBitrate = false
    @AppStorage("directRecordingMbps", store: userDefaults) private var mbps = 8
    @AppStorage("directRecordingEdge", store: userDefaults) private var edge = 1920
    @AppStorage("directRecordingFPS", store: userDefaults) private var fps = 60
    @AppStorage("recordingSegmentSeconds", store: userDefaults) private var segment = 120
    var body: some View {
        Toggle("可控分段錄製（測試中）", isOn: $enabled)
        if enabled {
            Picker("每段時長", selection: $segment) {
                ForEach([60, 120, 300, 600], id: \.self) { Text("\($0 / 60) 分鐘").tag($0) }
            }
            Picker("錄製編碼", selection: $codec) {
                Text("HEVC").tag("hevc")
                Text("H.264").tag("h264")
            }
            Toggle("碼率由編碼器自動決定", isOn: $automaticBitrate)
            if !automaticBitrate {
            Stepper("錄製平均碼率：\(mbps) Mbps", value: $mbps, in: 1...40)
            }
            Picker("錄製最長邊", selection: $edge) {
                Text("保留 Mixer 尺寸").tag(0)
                ForEach([1280, 1920, 2560], id: \.self) { Text("\($0) px").tag($0) }
            }
            Picker("錄製 FPS 上限", selection: $fps) {
                Text("不額外限制").tag(0)
                Text("30").tag(30)
                Text("60").tag(60)
            }
            Text("直接編碼為 MP4，每段獨立保存；應用與麥克風音量即時套用。沿用推流畫布、左轉與疊加設定，不再執行系統錄影的方向修正或錄後壓縮。切段可能有短暫缺口，意外中止時最後片段仍需驗證。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
