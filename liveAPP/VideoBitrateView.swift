import SwiftUI
import PhotosUI
import Charts

struct VideoBitrateView: View {
    @State private var selectedPickerItem: PhotosPickerItem?
    @State private var selectedFileURL: URL?
    @State private var isAnalyzing = false
    @State private var result: VideoAnalysisResult?
    @State private var errorMessage: String?
    @State private var showFilePicker = false
    @State private var showPhotosPicker = false
    @State private var tempFileURLs: [URL] = []

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.movie, .video, UTType("com.apple.quicktime-movie")].compactMap { $0 },
                allowsMultipleSelection: false
            ) { fileResult in
                switch fileResult {
                case .success(let urls):
                    if let url = urls.first {
                        startAnalysis(url: url)
                    }
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
            .photosPicker(isPresented: $showPhotosPicker, selection: $selectedPickerItem, matching: .videos)
            .onChange(of: selectedPickerItem) { newItem in
                guard let item = newItem else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("mov")
                    try? data.write(to: tempURL)
                    tempFileURLs.append(tempURL)
                    selectedPickerItem = nil
                    startAnalysis(url: tempURL)
                }
            }
            .onDisappear {
                cleanupTempFiles()
            }
            .alert("錯誤", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ), actions: {
                Button("確定") { errorMessage = nil }
            }, message: {
                Text(errorMessage ?? "")
            })
    }

    @ViewBuilder
    private var content: some View {
        if let result = result {
            resultView(result)
        } else if isAnalyzing {
            loadingView
        } else {
            placeholderView
        }
    }

    private var placeholderView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "video.badge.plus")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("選擇一個視頻來查看碼率資訊")
                .font(.headline)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                Button {
                    showPhotosPicker = true
                } label: {
                    Label("從相簿", systemImage: "photo.on.rectangle")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }

                Button {
                    showFilePicker = true
                } label: {
                    Label("從檔案", systemImage: "folder")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.accentColor.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }

            Spacer()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            Text("正在分析視頻...")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("讀取軌道資訊和碼率樣本")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    private func resultView(_ result: VideoAnalysisResult) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Text("視頻碼率分析")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Spacer()
                    Menu {
                        Button {
                            showPhotosPicker = true
                        } label: {
                            Label("從相簿", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showFilePicker = true
                        } label: {
                            Label("從檔案", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.title2)
                            .padding(8)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal)
                .padding(.top)
                .padding(.bottom, 8)

                VStack(spacing: 16) {
                    fileInfoSection(result)
                    bitrateChartSection(result)
                    videoTracksSection(result)
                    audioTracksSection(result)
                    if !result.bitrateSamples.isEmpty {
                        bitrateTimelineChart(result)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
    }

    private func fileInfoSection(_ result: VideoAnalysisResult) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                infoRow(label: "檔案名稱", value: result.fileName)
                Divider()
                infoRow(label: "檔案大小", value: result.formattedFileSize)
                Divider()
                infoRow(label: "時長", value: result.formattedDuration)
                Divider()
                infoRow(label: "平均碼率", value: result.formattedAverageBitrate, highlight: true)
            }
        } label: {
            Label("影片資訊", systemImage: "doc.text")
        }
    }

    private func bitrateChartSection(_ result: VideoAnalysisResult) -> some View {
        GroupBox {
            Chart {
                ForEach(result.videoTracks) { track in
                    BarMark(
                        x: .value("類型", "視頻"),
                        y: .value("碼率", track.bitrate / 1000)
                    )
                    .foregroundStyle(.blue)
                }
                ForEach(result.audioTracks) { track in
                    BarMark(
                        x: .value("類型", "音頻"),
                        y: .value("碼率", track.bitrate / 1000)
                    )
                    .foregroundStyle(.green)
                }
                BarMark(
                    x: .value("類型", "平均"),
                    y: .value("碼率", result.averageBitrate / 1000)
                )
                .foregroundStyle(.orange.opacity(0.6))
            }
            .chartYAxisLabel("Kbps")
            .chartXAxisLabel("軌道")
            .frame(height: 200)
        } label: {
            Label("碼率對比", systemImage: "chart.bar.fill")
        }
    }

    private func bitrateTimelineChart(_ result: VideoAnalysisResult) -> some View {
        GroupBox {
            Chart(result.bitrateSamples) { sample in
                LineMark(
                    x: .value("時間", sample.time),
                    y: .value("碼率", sample.bitrate / 1000)
                )
                .interpolationMethod(.monotone)

                AreaMark(
                    x: .value("時間", sample.time),
                    y: .value("碼率", sample.bitrate / 1000)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.blue.opacity(0.1))
            }
            .chartYAxisLabel("Kbps")
            .chartXAxisLabel("秒")
            .frame(height: 250)
        } label: {
            Label("碼率隨時間變化", systemImage: "waveform.path.ecg")
        }
    }

    private func videoTracksSection(_ result: VideoAnalysisResult) -> some View {
        ForEach(result.videoTracks) { track in
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    infoRow(label: "編碼格式", value: track.codec)
                    Divider()
                    infoRow(label: "解析度", value: resolutionString(track.resolution))
                    Divider()
                    infoRow(label: "幀率", value: String(format: "%.2f fps", track.frameRate ?? 0))
                    Divider()
                    infoRow(label: "碼率", value: bitrateString(track.bitrate), highlight: true)
                }
            } label: {
                Label("視頻軌", systemImage: "video")
            }
        }
    }

    private func audioTracksSection(_ result: VideoAnalysisResult) -> some View {
        ForEach(result.audioTracks) { track in
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    infoRow(label: "編碼格式", value: track.codec)
                    Divider()
                    if let sampleRate = track.audioSampleRate, sampleRate > 0 {
                        infoRow(label: "取樣率", value: String(format: "%.0f Hz", sampleRate))
                        Divider()
                    }
                    if let channels = track.audioChannels {
                        infoRow(label: "聲道", value: "\(channels) 聲道")
                        Divider()
                    }
                    infoRow(label: "碼率", value: bitrateString(track.bitrate), highlight: true)
                }
            } label: {
                Label("音頻軌", systemImage: "waveform")
            }
        }
    }

    private func infoRow(label: String, value: String, highlight: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(highlight ? .headline : .body)
                .foregroundColor(highlight ? .primary : .primary)
        }
    }

    private func resolutionString(_ size: CGSize?) -> String {
        guard let size = size, size.width > 0, size.height > 0 else { return "N/A" }
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    private func bitrateString(_ bitrate: Double) -> String {
        let kbps = bitrate / 1000
        if kbps > 1000 {
            return String(format: "%.2f Mbps (%.0f Kbps)", kbps / 1000, kbps)
        }
        return String(format: "%.0f Kbps", kbps)
    }

    private func cleanupTempFiles() {
        for url in tempFileURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempFileURLs.removeAll()
    }

    private func startAnalysis(url: URL) {
        isAnalyzing = true
        errorMessage = nil
        result = nil
        cleanupTempFiles()

        let accessing = url.startAccessingSecurityScopedResource()

        Task {
            let analysis = await VideoBitrateAnalyzer.analyze(url: url)
            if accessing { url.stopAccessingSecurityScopedResource() }

            await MainActor.run {
                isAnalyzing = false
                if let analysis = analysis {
                    self.result = analysis
                } else {
                    self.errorMessage = "無法分析此視頻檔案"
                }
            }
        }
    }
}
