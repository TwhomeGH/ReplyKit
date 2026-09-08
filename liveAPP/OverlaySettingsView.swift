import SwiftUI
import UIKit

final class OverlaySettingsViewModel: ObservableObject {
    @Published var config: OverlaySceneConfig {
        didSet {
            guard config != oldValue else { return }
            save()
        }
    }

    init() {
        config = OverlayConfigStore.load()
    }

    func reset() {
        config = OverlaySceneConfig()
    }

    private func save() {
        OverlayConfigStore.save(config)
        SocketServer.shared.pushOverlayConfig()
    }
}

struct OverlaySettingsView: View {
    @StateObject private var viewModel = OverlaySettingsViewModel()

    var body: some View {
        Form {
            Section {
                OverlayPreview(config: viewModel.config)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))

                Toggle("outputOverlay.enable", isOn: $viewModel.config.enabled)
            }

            Section(header: Text("outputOverlay.timeLayer.section")) {
                Toggle("outputOverlay.timeLayer.showTime", isOn: $viewModel.config.time.enabled)
                    .disabled(!viewModel.config.enabled)

                Picker(AppLanguage.localized("outputOverlay.timeLayer.content"), selection: $viewModel.config.time.format) {
                    ForEach(TimeOverlayFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("outputOverlay.timeLayer.position")
                    OverlayAnchorGrid(selection: $viewModel.config.time.anchor)
                }

                Stepper("\(AppLanguage.localized("outputOverlay.timeLayer.fontSize")) \(Int(viewModel.config.time.fontSize))", value: $viewModel.config.time.fontSize, in: 10...48, step: 1)

                Picker(AppLanguage.localized("outputOverlay.timeLayer.fontWeight"), selection: $viewModel.config.time.fontWeight) {
                    ForEach(OverlayFontWeight.allCases) { weight in
                        Text(weight.title).tag(weight)
                    }
                }

                ColorPicker(AppLanguage.localized("outputOverlay.timeLayer.textColor"), selection: Binding(
                    get: { Color(hex: viewModel.config.time.textColorHex) ?? .white },
                    set: { viewModel.config.time.textColorHex = $0.hexString }
                ))
            }

            Section(header: Text("outputOverlay.background.section")) {
                Toggle("outputOverlay.background.enabled", isOn: $viewModel.config.time.backgroundEnabled)

                ColorPicker(AppLanguage.localized("outputOverlay.background.color"), selection: Binding(
                    get: { Color(hex: viewModel.config.time.backgroundColorHex) ?? .black },
                    set: { viewModel.config.time.backgroundColorHex = $0.hexString }
                ))
                .disabled(!viewModel.config.time.backgroundEnabled)

                Slider(value: $viewModel.config.time.backgroundOpacity, in: 0...1, step: 0.05) {
                    Text("outputOverlay.background.opacity")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("1")
                }
                .disabled(!viewModel.config.time.backgroundEnabled)

                Stepper("\(AppLanguage.localized("outputOverlay.background.cornerRadius")) \(Int(viewModel.config.time.cornerRadius))", value: $viewModel.config.time.cornerRadius, in: 0...24, step: 1)
                    .disabled(!viewModel.config.time.backgroundEnabled)
            }

            Section(header: Text("outputOverlay.spacing.section")) {
                Stepper("\(AppLanguage.localized("outputOverlay.spacing.marginX")) \(Int(viewModel.config.time.marginX))", value: $viewModel.config.time.marginX, in: 0...160, step: 2)
                Stepper("\(AppLanguage.localized("outputOverlay.spacing.marginY")) \(Int(viewModel.config.time.marginY))", value: $viewModel.config.time.marginY, in: 0...160, step: 2)
                Stepper("\(AppLanguage.localized("outputOverlay.spacing.offsetX")) \(Int(viewModel.config.time.offsetX))", value: $viewModel.config.time.offsetX, in: -240...240, step: 2)
                Stepper("\(AppLanguage.localized("outputOverlay.spacing.offsetY")) \(Int(viewModel.config.time.offsetY))", value: $viewModel.config.time.offsetY, in: -240...240, step: 2)
            }

            Section {
                Button("common.resetDefaults") {
                    viewModel.reset()
                }
            }
        }
        .navigationTitle("settings.outputOverlay.title")
    }
}

private struct OverlayPreview: View {
    let config: OverlaySceneConfig

    private var previewText: String {
        switch config.time.format {
        case .timeOnly: return "20:26:09"
        case .dateTime: return "2026/09/08 20:26:09"
        case .elapsed: return "01:23:45"
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let canvas = CGSize(width: proxy.size.width, height: proxy.size.width * 9 / 16)
            let item = previewItemSize
            let point = config.time.anchor.origin(
                container: canvas,
                item: item,
                marginX: CGFloat(config.time.marginX),
                marginY: CGFloat(config.time.marginY),
                offsetX: CGFloat(config.time.offsetX),
                offsetY: CGFloat(config.time.offsetY)
            )

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.08, green: 0.09, blue: 0.1), Color(red: 0.16, green: 0.18, blue: 0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(alignment: .center) {
                        Image(systemName: "rectangle.dashed")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(.white.opacity(0.22))
                    }

                if config.enabled && config.time.enabled {
                    Text(previewText)
                        .font(.system(size: CGFloat(config.time.fontSize), weight: swiftUIFontWeight(config.time.fontWeight), design: .monospaced))
                        .foregroundStyle(Color(hex: config.time.textColorHex) ?? .white)
                        .padding(.horizontal, CGFloat(config.time.paddingX))
                        .padding(.vertical, CGFloat(config.time.paddingY))
                        .background {
                            if config.time.backgroundEnabled {
                                RoundedRectangle(cornerRadius: CGFloat(config.time.cornerRadius))
                                    .fill((Color(hex: config.time.backgroundColorHex) ?? .black).opacity(config.time.backgroundOpacity))
                            }
                        }
                        .position(x: point.x + item.width * 0.5, y: point.y + item.height * 0.5)
                }
            }
            .frame(width: canvas.width, height: canvas.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
    }

    private var previewItemSize: CGSize {
        let font = UIFont.monospacedDigitSystemFont(ofSize: CGFloat(config.time.fontSize), weight: uiFontWeight(config.time.fontWeight))
        let textSize = (previewText as NSString).size(withAttributes: [.font: font])
        return CGSize(
            width: textSize.width + CGFloat(config.time.paddingX * 2),
            height: textSize.height + CGFloat(config.time.paddingY * 2)
        )
    }
}

private struct OverlayAnchorGrid: View {
    @Binding var selection: OverlayAnchor

    private let rows: [[OverlayAnchor]] = [
        [.topLeft, .topCenter, .topRight],
        [.centerLeft, .center, .centerRight],
        [.bottomLeft, .bottomCenter, .bottomRight]
    ]

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(rows, id: \.self) { row in
                GridRow {
                    ForEach(row) { anchor in
                        Button {
                            selection = anchor
                        } label: {
                            Image(systemName: iconName(anchor))
                                .frame(maxWidth: .infinity, minHeight: 38)
                        }
                        .buttonStyle(.bordered)
                        .tint(selection == anchor ? .blue : .secondary)
                        .accessibilityLabel(anchor.title)
                    }
                }
            }
        }
    }

    private func iconName(_ anchor: OverlayAnchor) -> String {
        switch anchor {
        case .topLeft: return "arrow.up.left"
        case .topCenter: return "arrow.up"
        case .topRight: return "arrow.up.right"
        case .centerLeft: return "arrow.left"
        case .center: return "dot.scope"
        case .centerRight: return "arrow.right"
        case .bottomLeft: return "arrow.down.left"
        case .bottomCenter: return "arrow.down"
        case .bottomRight: return "arrow.down.right"
        }
    }
}

private func swiftUIFontWeight(_ weight: OverlayFontWeight) -> Font.Weight {
    switch weight {
    case .regular: return .regular
    case .medium: return .medium
    case .bold: return .bold
    }
}

func uiFontWeight(_ weight: OverlayFontWeight) -> UIFont.Weight {
    switch weight {
    case .regular: return .regular
    case .medium: return .medium
    case .bold: return .bold
    }
}

private extension Color {
    init?(hex: String) {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") {
            raw.removeFirst()
        }
        guard raw.count == 6, let value = Int(raw, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xff) / 255.0,
            green: Double((value >> 8) & 0xff) / 255.0,
            blue: Double(value & 0xff) / 255.0
        )
    }

    var hexString: String {
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#FFFFFF"
        }
        return String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }
}
