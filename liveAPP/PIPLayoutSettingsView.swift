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
    @State private var previewMode: PIPLayoutPreviewMode = .normal

    var body: some View {
        Form {
            Section {
                Picker("預覽狀態", selection: $previewMode) {
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
                    adSpacing: PIPAdOverlaySpacing
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            }

            Section(header: Text("聊天室文字")) {
                Stepper("主訊息大小 \(PIPFontMain, specifier: "%.1f")", value: $PIPFontMain, in: 1...100, step: 0.1)
                    .onChange(of: PIPFontMain) { newVal in
                        LPConfig.shared.PIPChatFontMainSize = newVal
                        PIPService.shared.markOverlayDirty()
                    }

                Stepper("次要訊息大小 \(PIPFontSecond, specifier: "%.1f")", value: $PIPFontSecond, in: 1...100, step: 0.1)
                    .onChange(of: PIPFontSecond) { newVal in
                        LPConfig.shared.PIPChatFontSecondSize = newVal
                        PIPService.shared.markOverlayDirty()
                    }
            }

            Section(header: Text("贊助覆蓋")) {
                Stepper("內文字體 \(PIPAdOverlayFont, specifier: "%.1f")", value: $PIPAdOverlayFont, in: 1...100, step: 0.1)
                    .onChange(of: PIPAdOverlayFont) { newVal in
                        LPConfig.shared.PIPAdOverlayFontSize = newVal
                        PIPService.shared.markOverlayDirty()
                    }

                Stepper("贊助者字體 \(PIPAdOverlayUserFont, specifier: "%.1f")", value: $PIPAdOverlayUserFont, in: 1...100, step: 0.1)
                    .onChange(of: PIPAdOverlayUserFont) { newVal in
                        LPConfig.shared.PIPAdOverlayUserFontSize = newVal
                        PIPService.shared.markOverlayDirty()
                    }

                Stepper("名稱與內文間距 \(PIPAdOverlaySpacing, specifier: "%.1f")", value: $PIPAdOverlaySpacing, in: 0...50, step: 0.5)
                    .onChange(of: PIPAdOverlaySpacing) { newVal in
                        LPConfig.shared.PIPAdOverlaySpacing = newVal
                        PIPService.shared.markOverlayDirty()
                    }

                Stepper("停留秒數 \(PIPAdOverlayDuration, specifier: "%.1f")", value: $PIPAdOverlayDuration, in: 1...60, step: 0.5)
                    .onChange(of: PIPAdOverlayDuration) { newVal in
                        LPConfig.shared.PIPAdOverlayDuration = newVal
                        PIPService.shared.markOverlayDirty()
                    }
            }

            Section(header: Text("動畫")) {
                Stepper("淡出速度 \(fadeAlpha, specifier: "%.2f")", value: $fadeAlpha, in: 0...100, step: 0.01)
                    .onChange(of: fadeAlpha) { newVal in
                        LPConfig.shared.FadeAlpha = newVal
                        PIPService.shared.markOverlayDirty()
                    }

                Stepper("淡出間隔 \(fadeTime, specifier: "%.2f") 秒", value: $fadeTime, in: 0...100, step: 0.1)
                    .onChange(of: fadeTime) { newVal in
                        LPConfig.shared.MessageFadeTime = newVal
                        PIPService.shared.fadeTime(newVal)
                    }

                Stepper("滾動時間 \(scrollTime, specifier: "%.2f") 秒", value: $scrollTime, in: 0...100, step: 0.1)
                    .onChange(of: scrollTime) { newVal in
                        LPConfig.shared.ScrollTime = newVal
                        PIPService.shared.scrollTime(newVal)
                    }
            }
        }
        .navigationTitle("PIP排版加工")
    }
}

private enum PIPLayoutPreviewMode: String, CaseIterable, Identifiable {
    case normal
    case adOverlay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return "一般"
        case .adOverlay: return "贊助顯示中"
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

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = width * 2 / 3
            let scale = width / 300
            let topMargin = (mode == .adOverlay ? 210.0 : 65.0) * scale

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color(red: 0.07, green: 0.08, blue: 0.09))

                VStack(alignment: .leading, spacing: 4 * scale) {
                    messageRow(
                        name: "主播",
                        message: "今天測一下新的排版",
                        fontSize: mainFontSize,
                        accent: .cyan,
                        scale: scale
                    )

                    messageRow(
                        name: "觀眾",
                        message: "字體大小會即時跟著變",
                        fontSize: secondFontSize,
                        accent: .green,
                        scale: scale
                    )
                    .opacity(0.82)
                }
                .padding(.leading, 10 * scale)
                .padding(.top, topMargin)
                .frame(width: width * 0.88, alignment: .leading)

                elapsedBadge(scale: scale)
                    .position(x: (50 + 38) * scale, y: (20 + 8) * scale)

                nowTimeBadge(scale: scale, canvasWidth: width)
                    .position(x: width * 0.5, y: (40 + 13) * scale)

                if mode == .adOverlay {
                    sponsorBanner(scale: scale, canvasWidth: width)
                        .position(x: width * 0.5, y: sponsorCenterY(scale: scale))
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .aspectRatio(3.0 / 2.0, contentMode: .fit)
    }

    private func elapsedBadge(scale: CGFloat) -> some View {
        HStack(spacing: 4 * scale) {
            Image(systemName: "clock.fill")
                .font(.system(size: 14 * scale, weight: .medium))
                .foregroundStyle(.pink)

            Text("00:12:34")
                .font(.system(size: 14 * scale, weight: .regular, design: .monospaced))
                .foregroundStyle(.white)
        }
    }

    private func nowTimeBadge(scale: CGFloat, canvasWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("現在時間 ")
                .font(.system(size: 16 * scale, weight: .medium))
                .foregroundStyle(.cyan)

            Text("2026/09/09 上午00:48:31")
                .font(.system(size: 16 * scale, weight: .regular, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.45)
        }
        .padding(.horizontal, 6 * scale)
        .padding(.vertical, 4 * scale)
        .frame(maxWidth: canvasWidth - 12 * scale)
        .background(Color.black.opacity(0.45))
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
                Text("贊助者")
                    .font(.system(size: max(7, CGFloat(adUserFontSize) * scale), weight: .bold))
                    .foregroundStyle(.white)

                Text("謝謝支持，這段文字會照內文字體呈現")
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

    private func sponsorCenterY(scale: CGFloat) -> CGFloat {
        let labelHeight = UIFont.boldSystemFont(ofSize: max(1, CGFloat(adUserFontSize))).lineHeight
        let textHeight = UIFont.systemFont(ofSize: max(1, CGFloat(adFontSize))).lineHeight
        let bannerHeight = max(52, 6 + labelHeight + CGFloat(adSpacing) + textHeight * 2 + 4 + 4)
        return (85 + bannerHeight * 0.5) * scale
    }
}
