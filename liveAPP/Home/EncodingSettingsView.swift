import SwiftUI

/// 主頁編碼設定入口；只保存偏好，能力查詢不建立推流服務。
struct EncodingSettingsView: View {
    let usesScreenCaptureKit: Bool
    @AppStorage("h264level", store: userDefaults) private var h264level = "AutoHigh"
    @AppStorage("videoCodec", store: userDefaults) private var videoCodec = "H264"
    @AppStorage("hevcLevel", store: userDefaults) private var hevcLevel = "Main"
    @AppStorage("odstW", store: userDefaults) private var width = 0
    @AppStorage("odstH", store: userDefaults) private var height = 0
    @AppStorage("isLowLatencyRateControlEnabled", store: userDefaults) private var lowLatency = false
    @AppStorage("BufferCount", store: userDefaults) private var bufferCount = -1
    @AppStorage("screenCaptureKitVideoBufferMB", store: userDefaults)
    private var sckBufferMB = 32
    @AppStorage("screenCaptureKitVideoBufferDurationMS", store: userDefaults)
    private var sckBufferDurationMS = 150
    @AppStorage("replayKitVideoBufferMB", store: userDefaults)
    private var replayKitBufferMB = 15
    @AppStorage("replayKitVideoBufferDurationMS", store: userDefaults)
    private var replayKitBufferDurationMS = 100
    @State private var result: H264CapabilityResult?
    @State private var loading = false
    @State private var refreshID = 0
    @State private var consumedRefreshID = 0
    @State private var expanded = false
#if os(iOS)
    @ObservedObject private var capture = CaptureCoordinator.shared
#endif

    /// ScreenCaptureKit 推流目前使用一般 H.264 模式，HEVC 偏好保留給 ReplayKit。
    private var isH264: Bool { usesScreenCaptureKit || videoCodec == "H264" }
    private var busy: Bool {
#if os(iOS)
        capture.isBusy
#else
        false
#endif
    }

    /// 未指定輸出時使用參考尺寸；UI 明示它不是正在擷取的實際尺寸。
    private var request: H264CapabilityRequest {
        .init(width: width > 0 ? width : 1920, height: height > 0 ? height : 1080,
              lowLatency: !usesScreenCaptureKit && lowLatency)
    }

    /// 以解析後值對照系統選單；開啟畫面不寫入遷移，使用者選取時才保存。
    private var selection: Binding<String> {
        Binding(get: { H264EncodingProfile.resolve(h264level) }, set: { h264level = $0 })
    }

    var body: some View {
        GroupBox {
            DisclosureGroup(AppLanguage.localized("home.encoding"), isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    if usesScreenCaptureKit {
                        Text(AppLanguage.localized("encoding.sckH264")).font(.caption)
                    } else {
                        Picker(AppLanguage.localized("encoding.codec"), selection: $videoCodec) {
                            Text("H.264").tag("H264")
                            Text("HEVC").tag("HEVC")
                        }.pickerStyle(.segmented)
                    }
                    if isH264 {
                        h264Options
                    } else {
                        Picker("HEVC Profile", selection: $hevcLevel) {
                            ForEach(HEVCProfile.allCases) { profile in
                                Text(profile.rawValue).tag(profile.rawValue)
                            }
                        }
                        Text(AppLanguage.localized("encoding.hevcUnverified")).font(.caption)
                    }
                    bufferOptions
                    Text(AppLanguage.localized("home.nextStart"))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
        }
        .task(id: "\(request)-\(isH264)-\(busy)-\(refreshID)-\(expanded)") {
            result = nil
            loading = false
            guard expanded, isH264, !busy else { return }
            loading = true
            let refresh = refreshID != consumedRefreshID
            consumedRefreshID = refreshID
            let fetched = await H264EncoderCapabilities.shared.query(request, refresh: refresh)
            guard !Task.isCancelled else { return }
            result = fetched
            loading = false
        }
    }

    /// 未列出的保存值保留顯示，但不宣稱支援，也不偷偷改選其他 Profile。
    private var h264Options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLanguage.localized("encoding.conditions") + " \(request.width) × \(request.height) · "
                 + AppLanguage.localized(request.lowLatency ? "encoding.lowLatency" : "encoding.standard"))
                .font(.caption).foregroundStyle(.secondary)
            if width <= 0 || height <= 0 {
                Text(AppLanguage.localized("encoding.referenceSize")).font(.caption)
            }
            Picker("H.264 Profile / Level", selection: selection) {
                if !(result?.values.contains(selection.wrappedValue) ?? false) {
                    Text(H264EncodingProfile.title(selection.wrappedValue) + " · " + AppLanguage.localized("encoding.unverified"))
                        .tag(selection.wrappedValue)
                }
                ForEach(result?.values ?? [], id: \.self) { value in
                    Text(H264EncodingProfile.title(value)).tag(value)
                }
            }
            .disabled(loading || result?.values.isEmpty != false || busy)
            if loading {
                ProgressView(AppLanguage.localized("encoding.loading"))
            } else if busy {
                Text(AppLanguage.localized("encoding.busy")).font(.caption)
            } else if let result, result.values.isEmpty {
                Text(AppLanguage.localized("encoding.unavailable") + " (\(result.stage): \(result.status))")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(AppLanguage.localized("encoding.scope")).font(.caption).foregroundStyle(.secondary)
            Button(AppLanguage.localized("encoding.refresh")) { refreshID += 1 }
                .disabled(loading || busy)
        }
    }

    /// 這是 RTMP／VideoToolbox 的輸入緩衝，不是 GPU 畫布；ReplayKit 與 SCK 都會使用。
    private var bufferOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLanguage.localized("gpu.buffer.count"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField(AppLanguage.localized("gpu.buffer.placeholder"),
                          value: $bufferCount, format: .number)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .keyboardType(.numberPad)
                Stepper("", value: $bufferCount, in: -1...100)
                    .labelsHidden()
            }
            .onChange(of: bufferCount) { value in
                if value < -1 {
                    bufferCount = -1
                } else if value > 100 {
                    bufferCount = 100
                }
                CFNotificationCenterPostNotification(cfCenter,
                    CFNotificationName("MaxInfilght" as CFString), nil, nil, true)
            }
            Text(AppLanguage.localized("gpu.buffer.recommendation"))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            Text("編碼前原始影格佇列")
                .font(.caption.weight(.semibold))
            Text("這是 byte budget 與最長停留時間，不是 RTMP 待送 bytes；下一次推流生效。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            inputBufferRow("ScreenCaptureKit（主 App）",
                           budget: $sckBufferMB, duration: $sckBufferDurationMS,
                           budgets: [16, 24, 32, 48, 64],
                           durations: [100, 150, 200, 300, 500])
            inputBufferRow("ReplayKit（擴展）",
                           budget: $replayKitBufferMB, duration: $replayKitBufferDurationMS,
                           budgets: [8, 12, 16, 24],
                           durations: [100, 150, 200])
        }
    }

    /// 分開顯示兩種來源的 byte budget；ReplayKit 不應套用主 App 的 64 MB 上限。
    private func inputBufferRow(_ title: String, budget: Binding<Int>, duration: Binding<Int>,
                                budgets: [Int], durations: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption)
            HStack(spacing: 12) {
                Picker("上限", selection: budget) {
                    ForEach(budgets, id: \.self) { Text("\($0) MB").tag($0) }
                }
                .pickerStyle(.menu)
                Picker("停留", selection: duration) {
                    ForEach(durations, id: \.self) { Text("\($0) ms").tag($0) }
                }
                .pickerStyle(.menu)
            }
        }
    }
}
