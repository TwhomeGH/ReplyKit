#if os(iOS)
import Foundation
import CoreGraphics
import SwiftUI

/// 開錄時保存一份壓縮設定；系統原始錄影碼率不受此設定控制。
struct RecordingCompressionSettings: Sendable {
    /// 是否啟用錄後處理，預設關閉。
    let enabled: Bool
    /// true 使用 HEVC，false 使用 H.264；不是容器選項。
    let hevc: Bool
    /// 目標視訊平均碼率，單位 Mbps，範圍 1…40。
    let megabits: Int
    /// 最長邊像素上限；0 保留原尺寸，不放大。
    let longestEdge: Int
    /// 最高取樣頻率；0 不額外丟幀，其他支援值為 30、60。
    let fpsLimit: Int

    init(enabled: Bool, hevc: Bool, megabits: Int, longestEdge: Int, fpsLimit: Int) {
        self.enabled = enabled
        self.hevc = hevc
        self.megabits = min(40, max(1, megabits))
        self.longestEdge = [0, 1280, 1920, 2560].contains(longestEdge) ? longestEdge : 1920
        self.fpsLimit = [0, 30, 60].contains(fpsLimit) ? fpsLimit : 60
    }

    /// 保留長寬比、使用偶數尺寸，且不放大原始畫面。
    func outputSize(_ source: CGSize) -> CGSize {
        let scale = longestEdge == 0 ? 1 : min(1, CGFloat(longestEdge) / max(source.width, source.height))
        return CGSize(width: max(2, floor(source.width * scale / 2) * 2),
                      height: max(2, floor(source.height * scale / 2) * 2))
    }

    /// 十進位 MB，僅估視訊；音訊與容器另計，不是大小保證。
    var estimatedVideoMBPerMinute: Double { Double(megabits) * 60 / 8 }

    /// 讀取並驗證持久設定；缺少值時採關閉、HEVC、8 Mbps、1920、60 FPS。
    static func load(from defaults: UserDefaults) -> Self {
        .init(enabled: defaults.bool(forKey: "recordingCompress"),
              hevc: defaults.string(forKey: "recordingCompressionCodec") != "h264",
              megabits: defaults.object(forKey: "recordingCompressionMbps") as? Int ?? 8,
              longestEdge: defaults.object(forKey: "recordingCompressionEdge") as? Int ?? 1920,
              fpsLimit: defaults.object(forKey: "recordingCompressionFPS") as? Int ?? 60)
    }
}

/// 依原始 PTS 限制最高頻率，不補幀、不重排時間戳；單一轉碼工作持有。
struct RecordingFrameRateLimiter {
    /// 每秒允許的最高幀數；0 不限制。
    let limit: Int
    /// 最近接受的 PTS，單位秒；尚未接受影格時為 nil。
    private(set) var lastAccepted: Double?

    /// 拒絕無效或倒退的 PTS，接受時同步更新最近時間。
    mutating func accepts(seconds: Double) -> Bool {
        guard seconds.isFinite else { return false }
        if let lastAccepted {
            guard seconds > lastAccepted else { return false }
            if limit > 0 && seconds - lastAccepted < 1 / Double(limit) - 0.00001 { return false }
        }
        lastAccepted = seconds
        return true
    }
}

/// 本地錄影的錄後壓縮設定；與推流碼率分開保存。
struct RecordingCompressionSettingsView: View {
    @AppStorage("recordingCompress", store: userDefaults) private var enabled = false
    @AppStorage("recordingCompressionCodec", store: userDefaults) private var codec = "hevc"
    @AppStorage("recordingCompressionMbps", store: userDefaults) private var mbps = 8
    @AppStorage("recordingCompressionEdge", store: userDefaults) private var edge = 1920
    @AppStorage("recordingCompressionFPS", store: userDefaults) private var fps = 60

    var body: some View {
        DisclosureGroup("錄後壓縮（SDR）") {
            Toggle("完成錄影後壓縮", isOn: $enabled)
            if enabled {
                Picker("壓縮編碼", selection: $codec) {
                    Text("HEVC（H.265）").tag("hevc")
                    Text("H.264（相容性較高）").tag("h264")
                }
                Stepper("目標平均碼率：\(mbps) Mbps", value: $mbps, in: 1...40)
                Picker("最長邊上限", selection: $edge) {
                    Text("保留尺寸").tag(0)
                    ForEach([1280, 1920, 2560], id: \.self) { Text("\($0) px").tag($0) }
                }
                Picker("FPS 上限", selection: $fps) {
                    Text("保留").tag(0)
                    Text("30").tag(30)
                    Text("60").tag(60)
                }
                Text("視訊約 \(String(format: "%.0f", Double(mbps) * 7.5)) MB／分鐘，另加音訊與封裝；實際大小依內容而異。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("下次開錄生效。錄後處理需額外時間、讀寫與暫存空間，請保持 App 在前景；失敗或背景時間不足時保留原檔。音訊保留原 AAC，HDR 暫不壓縮。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
