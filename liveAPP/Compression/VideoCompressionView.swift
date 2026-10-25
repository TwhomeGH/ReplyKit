import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import VideoToolbox

/// 手動單檔壓縮；與錄影壓縮設定分開，結果可分享或交給既有分析頁。
struct VideoCompressionView: View {
    var initialURL: URL?
    @ObservedObject private var model = VideoCompressionModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var codec = "h264"
    @State private var mbps = 8
    @State private var edge = 0
    @State private var fps = 0
    @State private var audio = RecordingTranscoder.AudioMode.preserve

    var body: some View {
        Form {
            Section("來源影片") {
                Button("從檔案選擇影片") { importing = true }.disabled(model.busy)
                if let source = model.source { Text(source.lastPathComponent) }
                if let info = model.details {
                    Text("\(bytes(info.bytes)) · \(String(format: "%.1f", info.duration)) 秒")
                    Text("\(Int(info.displayed.width)) × \(Int(info.displayed.height)) · \(String(format: "%.2f", info.fps)) FPS")
                    Text("影片 \(info.videoCodec) · \(String(format: "%.2f", info.videoRate / 1_000_000)) Mbps · 音訊 \(info.audioCodecs)")
                }
            }
            Section("壓縮設定") {
                Picker("編碼", selection: $codec) {
                    Text("H.264").tag("h264")
                    if VideoEncoderCapabilities.isHardwareEncodeSupported(kCMVideoCodecType_HEVC) { Text("HEVC").tag("hevc") }
                }
                Picker("最長邊上限（保持比例）", selection: $edge) {
                    Text("保持原始").tag(0)
                    Text("1920 px").tag(1920)
                    Text("1280 px").tag(1280)
                    Text("2560 px").tag(2560)
                }
                Picker("FPS 上限", selection: $fps) {
                    Text("保持原始").tag(0)
                    Text("60").tag(60)
                    Text("30").tag(30)
                }
                if let info = model.details, info.videoRate.isFinite, info.videoRate > 0 {
                    Button("依來源建議碼率（約原始 70%）") {
                        mbps = min(40, max(1, Int((Double(info.videoRate) * 0.7 / 1_000_000).rounded())))
                    }
                }
                Stepper("平均影片碼率：\(mbps) Mbps", value: $mbps, in: 1...40)
                Picker("音訊", selection: $audio) {
                    Text("保留原 AAC").tag(RecordingTranscoder.AudioMode.preserve)
                    Text("轉 AAC 128 kbps").tag(RecordingTranscoder.AudioMode.aac)
                    Text("移除音訊").tag(RecordingTranscoder.AudioMode.remove)
                }
                if let info = model.details {
                    Text(String(format: "預估影片部分約 %.1f MB，音訊與容器另計。", info.duration * Double(mbps) / 8))
                        .font(.caption)
                }
                Text("輸出 MP4，不放大或補幀。HDR 暫不支援；裝置編碼能力會於開始時檢查。轉 AAC 支援單／雙聲道。輸出不保證比原片小。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy)
            Section("工作狀態") {
                Text(model.message)
                if model.busy {
                    ProgressView(value: model.progress)
                    Text(String(format: "%.0f%%", model.progress * 100))
                    Button("取消", role: .cancel) { model.cancel() }
                } else {
                    Button("開始壓縮") {
                        model.start(settings: .init(enabled: true, hevc: codec == "hevc",
                            megabits: mbps, longestEdge: edge, fpsLimit: fps), audio: audio)
                    }.disabled(model.source == nil)
                }
                Text("請保持前景；切到背景會取消。偵測到擷取或近期 ReplayKit 推流回報時會等待；擴展斷線可能無法偵測，請先停止廣播。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let output = model.output {
                Section("壓縮結果") {
                    if let original = model.details, let result = model.outputDetails {
                        Text("原始 \(bytes(original.bytes)) → 輸出 \(bytes(result.bytes))")
                        let saved = original.bytes - result.bytes
                        Text("\(saved >= 0 ? "減少" : "增加") \(bytes(abs(saved)))（\(String(format: "%.1f", original.bytes > 0 ? Double(abs(saved)) / Double(original.bytes) * 100 : 0))%）")
                    }
                    ShareLink(item: output) { Label("分享影片", systemImage: "square.and.arrow.up") }
                    NavigationLink("播放與詳細資訊") { RecordingDetailsView(url: output) }
                    NavigationLink("分析輸出碼率") { VideoBitrateView(initialURL: output) }
                    Text("檔案 App → 此 App → CompressedVideos").font(.caption)
                }
            }
        }
        .navigationTitle("影片壓縮")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { model.select(url) }
            case .failure(let error): model.report(error)
            }
        }
        .onAppear { if let initialURL, !model.busy, model.source != initialURL { model.select(initialURL) } }
        .onChange(of: scenePhase) { phase in if phase == .background { model.cancel() } }
    }

    /// 以使用者可讀單位呈現，保留原始 bytes 供結果比較。
    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
