#if os(iOS) && canImport(UIKit)
import CoreGraphics
import Foundation
import UIKit

/// 依 `OverlaySceneConfig`（目前為時間層）raster 出疊加圖，供 ScreenCaptureKit 推流在影像 worker
/// 疊到已旋轉的 BGRA 畫面上（對齊 ReplayKit 既有輸出疊加行為）。
///
/// 每秒或設定變更才重建，frame path 只讀快取。座標採**左上原點**（與 `OverlayAnchor.origin` 一致）。
final class ScreenOverlayComposer: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter = DateFormatter()
    private let startedAt = Date()
    private var cachedConfig: TimeOverlayConfig?
    private var cachedSecond = -1
    private var cachedImage: CGImage?
    private var cachedSize: CGSize = .zero
    private var loggedConfig: TimeOverlayConfig?

    /// 要在 `canvas` 上繪製的疊加圖、左上原點與尺寸；未啟用時 nil。
    func layer(canvas: CGSize) -> (image: CGImage, origin: CGPoint, size: CGSize)? {
        let scene = OverlayConfigStore.load()
        guard scene.enabled, scene.time.enabled else { return nil }
        let timeCfg = scene.time
        let second = Int(Date().timeIntervalSince1970)

        lock.lock()
        if cachedImage == nil || cachedSecond != second || cachedConfig != timeCfg {
            if let raster = rasterize(timeCfg, second: second) {
                cachedImage = raster.image
                cachedSize = raster.size
                cachedSecond = second
                cachedConfig = timeCfg
            } else {
                lock.unlock()
                return nil
            }
        }
        let image = cachedImage
        let size = cachedSize
        lock.unlock()

        if loggedConfig != timeCfg {
            loggedConfig = timeCfg
            sendlog(message: "[CaptureOverlay] config applied enabled:\(scene.enabled) time:\(timeCfg.enabled) anchor:\(timeCfg.anchor.rawValue) size:\(Int(size.width))x\(Int(size.height))")
        }

        guard let image else { return nil }
        let origin = timeCfg.anchor.origin(
            container: canvas,
            item: size,
            marginX: CGFloat(timeCfg.marginX),
            marginY: CGFloat(timeCfg.marginY),
            offsetX: CGFloat(timeCfg.offsetX),
            offsetY: CGFloat(timeCfg.offsetY)
        )
        return (image, origin, size)
    }

    private func rasterize(_ config: TimeOverlayConfig, second: Int) -> (image: CGImage, size: CGSize)? {
        let text = timeText(config: config, now: Date(timeIntervalSince1970: TimeInterval(second)))
        let font = UIFont.monospacedDigitSystemFont(
            ofSize: max(1, CGFloat(config.fontSize)),
            weight: uiFontWeight(config.fontWeight)
        )
        let color = UIColor(overlayHex: config.textColorHex) ?? .white
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let paddingX = max(0, CGFloat(config.paddingX))
        let paddingY = max(0, CGFloat(config.paddingY))
        let width = max(1, Int(ceil(textSize.width + paddingX * 2)))
        let height = max(1, Int(ceil(textSize.height + paddingY * 2)))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { _ in
            if config.backgroundEnabled {
                let background = (UIColor(overlayHex: config.backgroundColorHex) ?? .black)
                    .withAlphaComponent(CGFloat(config.backgroundOpacity))
                background.setFill()
                UIBezierPath(
                    roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                    cornerRadius: CGFloat(config.cornerRadius)
                ).fill()
            }
            (text as NSString).draw(at: CGPoint(x: paddingX, y: paddingY), withAttributes: attrs)
        }
        guard let cg = image.cgImage else { return nil }
        return (cg, CGSize(width: width, height: height))
    }

    private func timeText(config: TimeOverlayConfig, now: Date) -> String {
        switch config.format {
        case .timeOnly, .dateTime:
            formatter.dateFormat = config.format.dateFormat
            return formatter.string(from: now)
        case .elapsed:
            let total = max(0, Int(now.timeIntervalSince(startedAt)))
            return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
    }
}

private func uiFontWeight(_ weight: OverlayFontWeight) -> UIFont.Weight {
    switch weight {
    case .regular: return .regular
    case .medium: return .medium
    case .bold: return .bold
    }
}

private extension UIColor {
    convenience init?(overlayHex hex: String) {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") {
            raw.removeFirst()
        }
        guard raw.count == 6, let value = UInt64(raw, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((value & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(value & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }
}
#endif
