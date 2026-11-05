import SwiftUI

struct PIPLayoutSettingsView: View {
    @AppStorage("PIPFontMain", store: userDefaults) private var PIPFontMain = 14.0
    @AppStorage("PIPFontSecond", store: userDefaults) private var PIPFontSecond = 10.0
    @AppStorage("PIPAdOverlayFont", store: userDefaults) private var PIPAdOverlayFont = 13.0
    @AppStorage("PIPAdOverlayUserFont", store: userDefaults) private var PIPAdOverlayUserFont = 14.0
    @AppStorage("PIPAdOverlaySpacing", store: userDefaults) private var PIPAdOverlaySpacing = 4.5
    @AppStorage("PIPAdOverlayDuration", store: userDefaults) private var PIPAdOverlayDuration = 5.0
    @AppStorage("fadeAlpha", store: userDefaults) private var fadeAlpha = 0.08
    @AppStorage("fadeTime", store: userDefaults) private var fadeTime = 0.5
    @AppStorage("scrollTime", store: userDefaults) private var scrollTime = 0.2
    @AppStorage("PIPNowTimeLabelOverride", store: userDefaults) private var nowTimeLabelOverride = ""
    @AppStorage("PIPLiveLabelOverride", store: userDefaults) private var liveLabelOverride = ""
    @AppStorage("PIPEndedLabelOverride", store: userDefaults) private var endedLabelOverride = ""
    @State private var previewMode: PIPLayoutPreviewMode = .normal

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsPreview = false

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 900 && !dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 16) {
                    ScrollView { previewPanel.padding(.vertical, 12) }
                        .frame(width: min(520, geometry.size.width * 0.42))
                    Form { controlSections }
                }.padding(.horizontal, 16)
            } else {
                Form {
                    Section { previewPanel }
                    controlSections
                }
            }
        }
        .navigationTitle("settings.pipLayout.title")
        .sheet(isPresented: $showsPreview) {
            NavigationStack {
                preview.padding()
                    .navigationTitle("layout.preview")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("layout.done") { showsPreview = false }
                        }
                    }
            }
        }
    }

    /// 預覽只縮放顯示，不修改實際 PiP 畫布或字體設定。
    private var previewPanel: some View {
        VStack(spacing: 12) {
            Picker(AppLanguage.localized("pipLayout.preview.mode"), selection: $previewMode) {
                    ForEach(PIPLayoutPreviewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 400)
            preview.frame(maxWidth: 520)
            Button("layout.expandPreview") { showsPreview = true }
        }.frame(maxWidth: .infinity)
    }

    private var preview: some View {
        PIPLayoutPreview(
                    mode: previewMode,
                    mainFontSize: PIPFontMain,
                    secondFontSize: PIPFontSecond,
                    adFontSize: PIPAdOverlayFont,
                    adUserFontSize: PIPAdOverlayUserFont,
                    adSpacing: PIPAdOverlaySpacing,
                    nowTimeLabel: effectiveLabel(nowTimeLabelOverride, localizedKey: "pip.default.nowTimeLabel"),
                    liveLabel: effectiveLabel(liveLabelOverride, localizedKey: "pip.default.liveLabel"),
                    endedLabel: effectiveLabel(endedLabelOverride, localizedKey: "pip.default.endedLabel")
                )
    }

    @ViewBuilder private var controlSections: some View {
            Section(header: Text("pipLayout.statusText.section")) {
                TextField(AppLanguage.localized("pipLayout.statusText.nowTime.placeholder"), text: $nowTimeLabelOverride)
                    .onChange(of: nowTimeLabelOverride) { newVal in
                        nowTimeLabelOverride = limitedOverride(newVal)
                        LPConfig.shared.PIPNowTimeLabel = effectiveLabel(nowTimeLabelOverride, localizedKey: "pip.default.nowTimeLabel")
                        PIPService.shared.markOverlayDirty()
                    }

                TextField(AppLanguage.localized("pipLayout.statusText.live.placeholder"), text: $liveLabelOverride)
                    .onChange(of: liveLabelOverride) { newVal in
                        liveLabelOverride = limitedOverride(newVal)
                        LPConfig.shared.PIPLiveLabel = effectiveLabel(liveLabelOverride, localizedKey: "pip.default.liveLabel")
                        if !LPConfig.shared.StreamEnded {
                            LPConfig.shared.StreamEndMes = LPConfig.shared.PIPLiveLabel
                        }
                        PIPService.shared.markOverlayDirty()
                    }

                TextField(AppLanguage.localized("pipLayout.statusText.ended.placeholder"), text: $endedLabelOverride)
                    .onChange(of: endedLabelOverride) { newVal in
                        endedLabelOverride = limitedOverride(newVal)
                        LPConfig.shared.PIPEndedLabel = effectiveLabel(endedLabelOverride, localizedKey: "pip.default.endedLabel")
                        if LPConfig.shared.StreamEnded {
                            LPConfig.shared.StreamEndMes = LPConfig.shared.PIPEndedLabel
                        }
                        PIPService.shared.markOverlayDirty()
                    }

                Text("pipLayout.statusText.warning")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("pipLayout.chat.section")) {
                Stepper("\(AppLanguage.localized("pipLayout.chat.mainSize")) \(PIPFontMain, specifier: "%.1f")", value: $PIPFontMain, in: 1...100, step: 0.1)
                    .onChange(of: PIPFontMain) { newVal in
                        LPConfig.shared.PIPChatFontMainSize = newVal
                        PIPService.shared.markOverlayDirty()
                    }

                Stepper("\(AppLanguage.localized("pipLayout.chat.secondSize")) \(PIPFontSecond, specifier: "%.1f")", value: $PIPFontSecond, in: 1...100, step: 0.1)
                    .onChange(of: PIPFontSecond) { newVal in
                        LPConfig.shared.PIPChatFontSecondSize = newVal
                        PIPService.shared.markOverlayDirty()
                    }
            }

            Section(header: Text("pipLayout.ad.section")) {
                Stepper("\(AppLanguage.localized("pipLayout.ad.bodyFont")) \(PIPAdOverlayFont, specifier: "%.1f")", value: $PIPAdOverlayFont, in: 1...100, step: 0.1)
                    .onChange(of: PIPAdOverlayFont) { newVal in
                        LPConfig.shared.PIPAdOverlayFontSize = newVal
                        PIPService.shared.markOverlayDirty()
                    }

                Stepper("\(AppLanguage.localized("pipLayout.ad.userFont")) \(PIPAdOverlayUserFont, specifier: "%.1f")", value: $PIPAdOverlayUserFont, in: 1...100, step: 0.1)
                    .onChange(of: PIPAdOverlayUserFont) { newVal in
                        LPConfig.shared.PIPAdOverlayUserFontSize = newVal
                        PIPService.shared.markOverlayDirty()
                    }

                Stepper("\(AppLanguage.localized("pipLayout.ad.spacing")) \(PIPAdOverlaySpacing, specifier: "%.1f")", value: $PIPAdOverlaySpacing, in: 0...50, step: 0.5)
                    .onChange(of: PIPAdOverlaySpacing) { newVal in
                        LPConfig.shared.PIPAdOverlaySpacing = newVal
                        PIPService.shared.markOverlayDirty()
                    }

                Stepper("\(AppLanguage.localized("pipLayout.ad.duration")) \(PIPAdOverlayDuration, specifier: "%.1f")", value: $PIPAdOverlayDuration, in: 1...60, step: 0.5)
                    .onChange(of: PIPAdOverlayDuration) { newVal in
                        LPConfig.shared.PIPAdOverlayDuration = newVal
                        PIPService.shared.markOverlayDirty()
                    }
            }

            Section(header: Text("pipLayout.animation.section")) {
                Stepper("\(AppLanguage.localized("pipLayout.animation.fadeSpeed")) \(fadeAlpha, specifier: "%.2f")", value: $fadeAlpha, in: 0...100, step: 0.01)
                    .onChange(of: fadeAlpha) { newVal in
                        LPConfig.shared.FadeAlpha = newVal
                        PIPService.shared.markOverlayDirty()
                    }

                Stepper("\(AppLanguage.localized("pipLayout.animation.fadeInterval")) \(fadeTime, specifier: "%.2f") \(AppLanguage.localized("unit.seconds"))", value: $fadeTime, in: 0...100, step: 0.1)
                    .onChange(of: fadeTime) { newVal in
                        LPConfig.shared.MessageFadeTime = newVal
                        PIPService.shared.fadeTime(newVal)
                    }

                Stepper("\(AppLanguage.localized("pipLayout.animation.scrollTime")) \(scrollTime, specifier: "%.2f") \(AppLanguage.localized("unit.seconds"))", value: $scrollTime, in: 0...100, step: 0.1)
                    .onChange(of: scrollTime) { newVal in
                        LPConfig.shared.ScrollTime = newVal
                        PIPService.shared.scrollTime(newVal)
                    }
            }
    }

    private func limitedOverride(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .newlines)
        return String(trimmed.prefix(12))
    }

    private func effectiveLabel(_ value: String, localizedKey: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AppLanguage.localized(localizedKey) : String(trimmed.prefix(12))
    }
}

private enum PIPLayoutPreviewMode: String, CaseIterable, Identifiable {
    case normal
    case adOverlay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return AppLanguage.localized("pipLayout.preview.normal")
        case .adOverlay: return AppLanguage.localized("pipLayout.preview.adOverlay")
        }
    }
}

private struct PIPLayoutPreview: View {
    let mode: PIPLayoutPreviewMode
    let mainFontSize: Double
    let secondFontSize: Double
    let adFontSize: Double
    let adUserFontSize: Double
    let adSpacing: Double
    let nowTimeLabel: String
    let liveLabel: String
    let endedLabel: String

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = width * 2 / 3
            let scale = width / 300

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color(red: 0.07, green: 0.08, blue: 0.09))

                // 整幀由正式繪製器輸出（聊天＋時間＋贊助），預覽只負責縮放。
                Image(uiImage: previewFrame(mode: mode))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: width, height: height)

                systemControlBadge(systemName: "xmark", scale: scale)
                    .padding(.leading, PIPOverlayLayout.controlMargin * scale)
                    .padding(.top, PIPOverlayLayout.controlMargin * scale)

                systemControlBadge(systemName: "rectangle.on.rectangle", scale: scale)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, PIPOverlayLayout.controlMargin * scale)
                    .padding(.top, PIPOverlayLayout.controlMargin * scale)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .aspectRatio(3.0 / 2.0, contentMode: .fit)
        .frame(minHeight: 200)
    }

    /// 整幀由正式繪製器輸出：聊天用 `PIPServiceMessages` 快照，時間與贊助用共用 renderer。
    private func previewFrame(mode: PIPLayoutPreviewMode) -> UIImage {
        let secondaryMode = PIPDisplaySettings.secondaryMode
        let notice: String? = secondaryMode == "summary"
            ? "\(AppLanguage.localized("pipLayout.preview.viewerName"))：\(AppLanguage.localized("pipLayout.preview.secondMessage"))"
            : nil
        let showSecondaryChat = secondaryMode == "normal"
        let time = PIPTimeOverlayRenderer.Scene(
            elapsedString: "00:12:34",
            nowTimeText: "2026/09/09 00:48:31",
            nowTimeLabel: nowTimeLabel,
            statusText: mode == .normal ? liveLabel : endedLabel,
            statusEnded: mode == .adOverlay,
            viewerCount: 128,
            isReconnecting: false,
            reconnectText: "",
            secondaryNotice: notice
        )

        var ad: PIPAdOverlayRenderer.Scene?
        if mode == .adOverlay {
            let text = AppLanguage.localized("pipLayout.preview.adMessage")
            ad = PIPAdOverlayRenderer.Scene(
                user: AppLanguage.localized("pipLayout.preview.sponsorName"),
                text: text,
                range: NSRange(location: 0, length: (text as NSString).length),
                emojiPositionMap: [:],
                emojiImages: [],
                icon: nil,
                alpha: 1,
                userFontSize: CGFloat(adUserFontSize),
                textFontSize: CGFloat(adFontSize),
                spacing: CGFloat(adSpacing),
                pageIndex: 0,
                pageCount: 1,
                logSkipCounter: 1
            )
        }

        let main: (user: String, message: String, fontSize: CGFloat, avatar: UIImage?)? = mode == .normal
            ? (AppLanguage.localized("pipLayout.preview.hostName"),
               AppLanguage.localized("pipLayout.preview.mainMessage"),
               CGFloat(mainFontSize), nil)
            : nil
        let secondary: (user: String, message: String, fontSize: CGFloat, avatar: UIImage?)? = (mode == .normal && showSecondaryChat)
            ? (AppLanguage.localized("pipLayout.preview.viewerName"),
               AppLanguage.localized("pipLayout.preview.secondMessage"),
               CGFloat(secondFontSize), nil)
            : nil

        return PIPPreviewFrameRenderer.render(
            scene: .init(time: time, ad: ad, chatMain: main, chatSecondary: secondary)
        )
    }

    /// 系統關閉／返回鈕由系統繪製，預覽以佔位圈標出保留區。
    private func systemControlBadge(systemName: String, scale: CGFloat) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17 * scale, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: PIPOverlayLayout.controlDiameter * scale,
                   height: PIPOverlayLayout.controlDiameter * scale)
            .background(Circle().fill(Color.black.opacity(0.75)))
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: scale))
            .accessibilityLabel("系統 PiP 控制")
    }
}

