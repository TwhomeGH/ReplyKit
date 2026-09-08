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

    var body: some View {
        Form {
            Section {
                Picker(AppLanguage.localized("pipLayout.preview.mode"), selection: $previewMode) {
                    ForEach(PIPLayoutPreviewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

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
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            }

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
        .navigationTitle("settings.pipLayout.title")
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
            let metrics = PIPPreviewMetrics(scale: scale)
            let topMargin = metrics.chatTopY(mode: mode)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color(red: 0.07, green: 0.08, blue: 0.09))

                if mode == .normal {
                    VStack(alignment: .leading, spacing: 4 * scale) {
                        messageRow(
                            name: AppLanguage.localized("pipLayout.preview.hostName"),
                            message: AppLanguage.localized("pipLayout.preview.mainMessage"),
                            fontSize: mainFontSize,
                            accent: .cyan,
                            scale: scale
                        )

                        messageRow(
                            name: AppLanguage.localized("pipLayout.preview.viewerName"),
                            message: AppLanguage.localized("pipLayout.preview.secondMessage"),
                            fontSize: secondFontSize,
                            accent: .green,
                            scale: scale
                        )
                        .opacity(0.82)
                    }
                    .padding(.leading, metrics.messageLeading)
                    .padding(.top, topMargin)
                    .frame(width: width - metrics.messageLeading - 10 * scale, alignment: .leading)
                }

                HStack(spacing: 4 * scale) {
                    elapsedBadge(scale: scale)
                        .layoutPriority(3)
                    statusBadge(scale: scale)
                        .layoutPriority(2)
                    viewerBadge(scale: scale)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, metrics.elapsedX)
                .padding(.top, metrics.elapsedY - 2 * scale)
                .frame(width: width - metrics.elapsedX - 8 * scale, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

                nowTimeBadge(scale: scale, canvasWidth: width)
                    .position(x: width * 0.5, y: metrics.nowTimeCenterY)

                if mode == .adOverlay {
                    sponsorBanner(scale: scale, canvasWidth: width)
                        .position(x: width * 0.5, y: sponsorCenterY(metrics: metrics))
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .aspectRatio(3.0 / 2.0, contentMode: .fit)
        .frame(minHeight: 200)
    }

    private func elapsedBadge(scale: CGFloat) -> some View {
        HStack(spacing: 4 * scale) {
            Image(systemName: "clock.fill")
                .font(.system(size: 14 * scale, weight: .medium))
                .foregroundStyle(.pink)

            Text("00:12:34")
                .font(.system(size: 14 * scale, weight: .regular, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func nowTimeBadge(scale: CGFloat, canvasWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("\(nowTimeLabel) ")
                .font(.system(size: 16 * scale, weight: .medium))
                .foregroundStyle(.cyan)

            Text("2026/09/09 00:48:31")
                .font(.system(size: 16 * scale, weight: .regular, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.45)
        }
        .padding(.horizontal, 6 * scale)
        .padding(.vertical, 4 * scale)
        .frame(maxWidth: canvasWidth - 12 * scale)
        .background(Color.black.opacity(0.45))
        .lineLimit(1)
        .minimumScaleFactor(0.35)
    }

    private func statusBadge(scale: CGFloat) -> some View {
        Text(mode == .normal ? liveLabel : endedLabel)
            .font(.system(size: 14 * scale, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 8 * scale)
            .padding(.vertical, 2 * scale)
            .background((mode == .normal ? Color.orange : Color.gray).opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 4 * scale))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .truncationMode(.tail)
    }

    private func viewerBadge(scale: CGFloat) -> some View {
        HStack(spacing: 4 * scale) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 11 * scale, weight: .medium))

            Text("128")
                .font(.system(size: 14 * scale, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(Color(white: 0.16))
        .padding(.horizontal, 8 * scale)
        .padding(.vertical, 2 * scale)
        .background(Color(white: 0.83))
        .clipShape(Capsule())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func messageRow(name: String, message: String, fontSize: Double, accent: Color, scale: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 6 * scale) {
            Circle()
                .fill(accent.opacity(0.82))
                .frame(width: 18 * scale, height: 18 * scale)

            VStack(alignment: .leading, spacing: 1 * scale) {
                Text(name)
                    .font(.system(size: max(7, CGFloat(fontSize) * 0.75 * scale), weight: .bold))
                    .foregroundStyle(accent)

                Text(message)
                    .font(.system(size: max(7, CGFloat(fontSize) * scale), weight: .regular))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
        }
    }

    private func sponsorBanner(scale: CGFloat, canvasWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 8 * scale) {
            Circle()
                .fill(Color.white.opacity(0.92))
                .overlay {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12 * scale, weight: .bold))
                        .foregroundStyle(Color.orange)
                }
                .frame(width: 28 * scale, height: 28 * scale)

            VStack(alignment: .leading, spacing: max(0, CGFloat(adSpacing) * scale)) {
                Text("pipLayout.preview.sponsorName")
                    .font(.system(size: max(7, CGFloat(adUserFontSize) * scale), weight: .bold))
                    .foregroundStyle(.white)

                Text("pipLayout.preview.adMessage")
                    .font(.system(size: max(7, CGFloat(adFontSize) * scale), weight: .regular))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(8 * scale)
        .frame(width: canvasWidth * 0.88, alignment: .leading)
        .background(Color.orange.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sponsorCenterY(metrics: PIPPreviewMetrics) -> CGFloat {
        let labelHeight = UIFont.boldSystemFont(ofSize: max(1, CGFloat(adUserFontSize))).lineHeight
        let textHeight = UIFont.systemFont(ofSize: max(1, CGFloat(adFontSize))).lineHeight
        let bannerHeight = max(52, 6 + labelHeight + CGFloat(adSpacing) + textHeight * 2 + 4 + 4)
        return (metrics.sponsorY + bannerHeight * 0.5) * metrics.scale
    }
}

private struct PIPPreviewMetrics {
    let scale: CGFloat

    var elapsedX: CGFloat { 50 * scale }
    var elapsedY: CGFloat { 20 * scale }
    var nowTimeCenterY: CGFloat { (48 + 13) * scale }
    var sponsorY: CGFloat { 85 }
    var messageLeading: CGFloat { 10 * scale }

    func chatTopY(mode: PIPLayoutPreviewMode) -> CGFloat {
        let base = max(88, 200 * 0.26)
        let adOffset = mode == .adOverlay ? 145.0 : 0
        return (base + adOffset) * scale
    }
}
