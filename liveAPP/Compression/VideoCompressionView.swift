import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import VideoToolbox
import PhotosUI
import AVKit

/// 手動單檔壓縮；與錄影壓縮設定分開，結果可分享或交給既有分析頁。
struct VideoCompressionView: View {
    var initialURL: URL?
    @ObservedObject private var model = VideoCompressionModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var photoItem: PhotosPickerItem?
    @State private var loadingPhoto = false
    @State private var didLoadInitialURL = false
    @State private var systemQuality = false
    @State private var qualityPreset = RecordingTranscoder.QualityPreset.highest
    @State private var codec = "h264"
    @State private var mbps = 8.0
    @State private var suggestionFeedback = ""
    @State private var showingSuggestion = false
    @State private var edge = 0
    @State private var customSize = false
    @State private var width = 1920
    @State private var height = 1080
    @State private var customFPS = false
    @State private var customFPSValue = 60
    @State private var audioKbps = 128
    @State private var fps = 0
    @State private var audio = RecordingTranscoder.AudioMode.preserve

    var body: some View {
        Form {
            Section("來源影片") {
                PhotosPicker(selection: $photoItem, matching: .videos) {
                    Label("從相簿選擇影片", systemImage: "photo.on.rectangle")
                }
                .disabled(model.busy || loadingPhoto)
                Button("從檔案選擇影片") { importing = true }.disabled(model.busy || loadingPhoto)
                if loadingPhoto { ProgressView("正在讀取相簿影片…") }
                if let source = model.source { Text(source.lastPathComponent) }
                if let info = model.details {
                    Text("\(bytes(info.bytes)) · \(String(format: "%.1f", info.duration)) 秒")
                    Text("\(Int(info.displayed.width)) × \(Int(info.displayed.height)) · \(String(format: "%.2f", info.fps)) FPS")
                    Text("影片 \(info.videoCodec) · \(String(format: "%.2f", info.videoRate / 1_000_000)) Mbps")
                    Text(info.audioSummary).textSelection(.enabled)
                }
            }
            Section("壓縮設定") {
                Picker("壓縮模式", selection: $systemQuality) {
                    Text("自訂平均碼率").tag(false)
                    Text("系統品質預設").tag(true)
                }
                if systemQuality {
                    Picker("品質預設", selection: $qualityPreset) {
                        ForEach(model.qualityPresets, id: \.self) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    Text(model.qualityPresets.isEmpty ? "請先選片；此來源若無可用 MP4 預設，請使用自訂模式。" : "尺寸、FPS、影音編碼與碼率由系統預設管理；手動設定不套用。容量無法預估，最高品質不表示無損，也不保證縮小。HDR 暫不支援。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                Picker("編碼", selection: $codec) {
                    Text("H.264").tag("h264")
                    if VideoEncoderCapabilities.isHardwareEncodeSupported(kCMVideoCodecType_HEVC) { Text("HEVC").tag("hevc") }
                }
                Toggle("自訂寬高上限", isOn: $customSize)
                if customSize {
                    TextField("寬度上限（px）", value: $width, format: .number).keyboardType(.numberPad)
                    TextField("高度上限（px）", value: $height, format: .number).keyboardType(.numberPad)
                    Text("2…8192 px，保持比例、不放大、不裁切；實際尺寸取偶數，可能小於輸入上限。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                Picker("最長邊上限（保持比例）", selection: $edge) {
                    Text("保持原始").tag(0)
                    Text("1920 px").tag(1920)
                    Text("1280 px").tag(1280)
                    Text("2560 px").tag(2560)
                }
                }
                if let info = model.details, validOptions {
                    let size = compressionSettings.outputSize(info.displayed)
                    Text("預計顯示尺寸：\(Int(size.width)) × \(Int(size.height)) px")
                }
                Toggle("自訂 FPS 上限", isOn: $customFPS)
                if customFPS {
                    TextField("FPS（1…120）", value: $customFPSValue, format: .number).keyboardType(.numberPad)
                } else {
                Picker("FPS 上限", selection: $fps) {
                    Text("保持原始").tag(0)
                    Text("60").tag(60)
                    Text("30").tag(30)
                }
                }
                Button("依來源套用粗估碼率") { applySuggestedBitrate() }
                    .disabled(model.details == nil)
                Text("以來源影片碼率的 70% 粗估，限制在 0.1…40 Mbps；不評估內容複雜度、編碼、尺寸或 FPS 改變後的畫質。")
                    .font(.caption).foregroundStyle(.secondary)
                if !suggestionFeedback.isEmpty {
                    Label(suggestionFeedback, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                LabeledContent("影片平均碼率（Mbps）") {
                    TextField("0.1…40", value: $mbps, format: .number)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                HStack {
                    ForEach([1.0, 2.5, 4.0, 6.0, 8.0], id: \.self) { value in
                        Button(String(format: "%g", value)) { mbps = value; suggestionFeedback = "" }
                            .buttonStyle(.bordered)
                    }
                }
                Picker("音訊", selection: $audio) {
                    Text("保留原 AAC").tag(RecordingTranscoder.AudioMode.preserve)
                    Text("轉 AAC").tag(RecordingTranscoder.AudioMode.aac)
                    Text("移除音訊").tag(RecordingTranscoder.AudioMode.remove)
                }
                if audio == .aac {
                    Picker("AAC 碼率（每軌）", selection: $audioKbps) {
                        ForEach([64, 96, 128, 160, 192, 256, 320], id: \.self) { value in
                            Text("\(value) kbps").tag(value)
                        }
                    }
                }
                if !validOptions { Text("請輸入有效寬高、FPS 與碼率（0.1…40 Mbps）。").foregroundStyle(.red) }
                Text("輸出 MP4，不放大或補幀。HDR 暫不支援；裝置編碼能力會於開始時檢查。轉 AAC 支援單／雙聲道。輸出不保證比原片小。")
                    .font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(model.busy)
            outputSummary
            Section("工作狀態") {
                Text(model.message)
                if model.busy {
                    if model.systemExportRunning {
                        ProgressView("系統品質匯出中…")
                    } else {
                        ProgressView(value: model.progress)
                        Text(String(format: "%.0f%%", model.progress * 100))
                    }
                    Button("取消", role: .cancel) { model.cancel() }
                } else {
                    Button("開始壓縮") {
                        model.start(settings: compressionSettings, audio: audio, audioBitrate: audioKbps * 1000, qualityPreset: systemQuality ? qualityPreset : nil)
                    }.disabled(model.source == nil || !validOptions)
                }
                Text("請保持前景；切到背景會取消。偵測到擷取或近期 ReplayKit 推流回報時會等待；擴展斷線可能無法偵測，請先停止廣播。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let output = model.output {
                Section("壓縮結果") {
                    if let original = model.details, let result = model.outputDetails {
                        Text("原始 \(bytes(original.bytes)) → 輸出 \(bytes(result.bytes))")
                        Text(result.audioSummary).textSelection(.enabled)
                        let saved = original.bytes - result.bytes
                        Text("\(saved >= 0 ? "減少" : "增加") \(bytes(abs(saved)))（\(String(format: "%.1f", original.bytes > 0 ? Double(abs(saved)) / Double(original.bytes) * 100 : 0))%）")
                    }
                    ShareLink(item: output) { Label("分享影片", systemImage: "square.and.arrow.up") }
                    NavigationLink("播放壓縮影片") { CompressionPlaybackView(url: output) }
                    NavigationLink("詳細資訊") { RecordingDetailsView(url: output) }
                    NavigationLink("分析輸出碼率") { VideoBitrateView(initialURL: output) }
                    Text("檔案 App → 此 App → CompressedVideos").font(.caption)
                }
            }
        }
        .navigationTitle("影片壓縮")
        .alert("建議碼率", isPresented: $showingSuggestion) {
            Button("知道了", role: .cancel) { }
        } message: { Text(suggestionFeedback) }
        .onChange(of: model.qualityPresets) { presets in
            if !presets.contains(qualityPreset), let first = presets.first { qualityPreset = first }
        }
        .onChange(of: model.source) { _ in suggestionFeedback = "" }

        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { model.select(url) }
            case .failure(let error): model.report(error)
            }
        }
        // 只在首次出現帶入入口來源；從子頁返回時保留使用者後來選的影片。
        .onAppear {
            if !model.qualityPresets.contains(qualityPreset), let first = model.qualityPresets.first { qualityPreset = first }
            guard !didLoadInitialURL else { return }
            didLoadInitialURL = true
            if let initialURL, !model.busy { model.select(initialURL) }
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task { @MainActor in
                loadingPhoto = true
                defer {
                    loadingPhoto = false
                    photoItem = nil
                }
                do { model.selectImported(try await PhotoVideoImport.load(item)) }
                catch { model.report(error) }
            }
        }
        .onChange(of: scenePhase) { phase in if phase == .background { model.cancel() } }
    }

    /// 明確回報操作結果；原值相同與來源缺失也不可無聲略過。
    private func applySuggestedBitrate() {
        guard let info = model.details, info.videoRate.isFinite, info.videoRate > 0 else {
            suggestionFeedback = "來源未提供有效影片碼率，無法計算建議；目前設定未變更。"
            showingSuggestion = true
            return
        }
        let suggested = min(40, max(0.1, (Double(info.videoRate) * 0.7 / 100_000).rounded() / 10))
        let previous = mbps
        mbps = suggested
        suggestionFeedback = previous == suggested
            ? String(format: "上次操作：目前已是粗估建議值 %.1f Mbps。", suggested)
            : String(format: "上次套用：%g → %.1f Mbps（來源 %.2f Mbps × 70%%，取至 0.1 Mbps）。", previous, suggested, Double(info.videoRate) / 1_000_000)
        showingSuggestion = true
    }

    /// 估算包含所有音軌；任一保留音軌缺碼率時，不假裝能得出完整容量。
    private func estimatedAudioBitrate(_ info: RecordingFileDetails) -> Double? {
        switch audio {
        case .remove: return 0
        case .aac: return Double(audioKbps * 1000) * Double(info.audioTracks.count)
        case .preserve:
            guard info.audioTracks.allSatisfy({ $0.estimatedBitrate != nil }) else { return nil }
            return info.audioTracks.compactMap(\.estimatedBitrate).reduce(0, +)
        }
    }

    /// 開始前集中確認輸出設定；容量為平均碼率估算，尚未包含封裝。
    @ViewBuilder private var outputSummary: some View {
        if let info = model.details, validOptions, !systemQuality {
            Section("目前輸出設定") {
                let size = compressionSettings.outputSize(info.displayed)
                LabeledContent("格式", value: "MP4 · " + (codec == "hevc" ? "HEVC" : "H.264"))
                LabeledContent("預計顯示尺寸", value: "\(Int(size.width)) × \(Int(size.height)) px")
                LabeledContent("FPS 上限", value: compressionSettings.fpsLimit == 0 ? "保留來源" : "\(compressionSettings.fpsLimit)（不補幀）")
                LabeledContent("影片平均碼率", value: String(format: "%g Mbps", mbps))
                LabeledContent("音訊", value: audio == .remove ? "移除" : audio == .aac ? "AAC · 48 kHz · 每軌 \(audioKbps) kbps" : "保留來源 AAC")
                if let audioRate = estimatedAudioBitrate(info), info.duration.isFinite, info.duration > 0 {
                    let estimate = info.duration * (mbps * 1_000_000 + audioRate) / 8
                    Text(String(format: "預估影音容量：%.1f MB；原檔 %.1f MB。", estimate / 1_000_000, Double(info.bytes) / 1_000_000))
                    if estimate >= Double(info.bytes) {
                        Label("預估可能不會縮小，請降低碼率或調整輸出設定。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Text("未含容器封裝，實際大小依內容與編碼器而異；不是容量保證。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("來源音訊碼率或時長未提供，無法估算完整容量。")
                }
            }
        }
    }

    /// 開始前驗證輸入，避免設定正規化悄悄改掉手動輸入值。
    private var validOptions: Bool {
        if systemQuality { return model.qualityPresets.contains(qualityPreset) }
        return mbps.isFinite && (0.1...40).contains(mbps) &&
        (!customSize || ((2...8192).contains(width) && (2...8192).contains(height))) &&
        (!customFPS || (1...120).contains(customFPSValue))
    }

    /// 手動尺寸以顯示方向的邊界表示，轉碼器負責處理來源旋轉矩陣。
    private var compressionSettings: RecordingCompressionSettings {
        if systemQuality {
            return .init(enabled: true, hevc: qualityPreset == .hevcHighest,
                         megabits: 8, longestEdge: 0, fpsLimit: 0, systemQuality: true)
        }
        return .init(enabled: true, hevc: codec == "hevc", megabits: 8,
              longestEdge: customSize ? 0 : edge, fpsLimit: customFPS ? customFPSValue : fps,
              boundingSize: customSize ? CGSize(width: width, height: height) : nil,
              videoBitrate: mbps.isFinite && (0.1...40).contains(mbps) ? Int((mbps * 1_000_000).rounded()) : 8_000_000)
    }

    /// 以使用者可讀單位呈現，保留原始 bytes 供結果比較。
    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

/// 只在播放頁持有播放器；離頁釋放解碼資源，返回後可重新播放。
private struct CompressionPlaybackView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .navigationTitle("播放壓縮影片")
            .onAppear { player = AVPlayer(url: url) }
            .onDisappear {
                player?.pause()
                player?.replaceCurrentItem(with: nil)
                player = nil
            }
    }
}
