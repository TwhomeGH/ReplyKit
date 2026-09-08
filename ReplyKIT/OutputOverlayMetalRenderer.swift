import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import Metal
import UIKit

final class OutputOverlayMetalRenderer: @unchecked Sendable {
    static let shared = OutputOverlayMetalRenderer()

    private var pipeline: MTLComputePipelineState?
    private var cachedTextureKey: String?
    private var cachedTexture: (texture: MTLTexture, size: CGSize)?
    private var cachedSecond: Int = -1
    private var cachedText: String = ""
    private let formatter = DateFormatter()
    private let startedAt = Date()
    private let configLock = NSLock()
    private let textureLock = NSLock()
    private let logLock = NSLock()
    private var currentConfig = OverlayConfigStore.load()
    private var lastLogTimes: [String: CFAbsoluteTime] = [:]
    private var overlayFrameCount: UInt64 = 0
    private var lastOverlayDurationLogTime: CFAbsoluteTime = 0

    private init() {}

    func applyIfNeeded(commandBuffer: MTLCommandBuffer, dstY: MTLTexture, dstUV: MTLTexture) {
        let config = loadCurrentConfig()
        guard config.enabled, config.time.enabled else { return }
        guard ensurePipeline() else { return }
        let start = CFAbsoluteTimeGetCurrent()
        guard let item = makeTimeTexture(config: config.time) else { return }

        let canvas = CGSize(width: dstY.width, height: dstY.height)
        let origin = config.time.anchor.origin(
            container: canvas,
            item: item.size,
            marginX: CGFloat(config.time.marginX),
            marginY: CGFloat(config.time.marginY),
            offsetX: CGFloat(config.time.offsetX),
            offsetY: CGFloat(config.time.offsetY)
        )

        var params = OverlayCompositeParams(
            originX: UInt32(max(0, Int(origin.x.rounded()))),
            originY: UInt32(max(0, Int(origin.y.rounded()))),
            overlayWidth: UInt32(max(0, Int(item.size.width.rounded()))),
            overlayHeight: UInt32(max(0, Int(item.size.height.rounded()))),
            dstWidth: UInt32(dstY.width),
            dstHeight: UInt32(dstY.height),
            opacity: 1.0
        )

        guard let encoder = commandBuffer.makeComputeCommandEncoder(),
              let pipeline else { return }

        encoder.label = "ReplyKit.output.overlay"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(item.texture, index: 0)
        encoder.setTexture(dstY, index: 1)
        encoder.setTexture(dstUV, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<OverlayCompositeParams>.stride, index: 0)

        let tgWidth = pipeline.threadExecutionWidth
        let tgHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / tgWidth)
        encoder.dispatchThreads(
            MTLSize(width: item.texture.width, height: item.texture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tgWidth, height: tgHeight, depth: 1)
        )
        encoder.endEncoding()
        recordOverlayDuration(start: start)
    }

    func clearCache() {
        textureLock.lock()
        cachedTextureKey = nil
        cachedTexture = nil
        cachedSecond = -1
        cachedText = ""
        textureLock.unlock()
    }

    func reloadConfig() {
        configLock.lock()
        currentConfig = OverlayConfigStore.load()
        configLock.unlock()
        clearCache()
    }

    func apply(config: OverlaySceneConfig, persist: Bool = true) {
        if persist {
            OverlayConfigStore.save(config)
        }
        configLock.lock()
        currentConfig = config
        configLock.unlock()
        clearCache()
        sendlog(message: "[OverlayMetal] config applied enabled:\(config.enabled) time:\(config.time.enabled)")
    }

    private func loadCurrentConfig() -> OverlaySceneConfig {
        configLock.lock()
        defer { configLock.unlock() }
        return currentConfig
    }

    private func ensurePipeline() -> Bool {
        if pipeline != nil { return true }
        do {
            guard let function = MetalContext.shared.library.makeFunction(name: "compositeOverlayBGRAToNV12") else {
                logThrottled("missingCompositeFunction", interval: 5) {
                    "[OverlayMetal] compositeOverlayBGRAToNV12 not found"
                }
                return false
            }
            pipeline = try MetalContext.shared.device.makeComputePipelineState(function: function)
            return true
        } catch {
            logThrottled("pipelineFailed", interval: 5) {
                "[OverlayMetal] pipeline failed: \(error.localizedDescription)"
            }
            return false
        }
    }

    private func makeTimeTexture(config: TimeOverlayConfig) -> (texture: MTLTexture, size: CGSize)? {
        let text = cachedTimeText(config: config)
        let key = [
            text,
            "\(config.fontSize)",
            config.fontWeight.rawValue,
            config.textColorHex,
            "\(config.backgroundEnabled)",
            config.backgroundColorHex,
            "\(config.backgroundOpacity)",
            "\(config.cornerRadius)",
            "\(config.paddingX)",
            "\(config.paddingY)"
        ].joined(separator: "|")

        textureLock.lock()
        let cached = cachedTextureKey == key ? cachedTexture : nil
        textureLock.unlock()
        if let cached {
            return cached
        }

        let font = UIFont.monospacedDigitSystemFont(
            ofSize: max(1, CGFloat(config.fontSize)),
            weight: uiFontWeight(config.fontWeight)
        )
        let textColor = UIColor(overlayHex: config.textColorHex) ?? .white
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let paddingX = max(0, CGFloat(config.paddingX))
        let paddingY = max(0, CGFloat(config.paddingY))
        let width = max(1, Int(ceil(textSize.width + paddingX * 2)))
        let height = max(1, Int(ceil(textSize.height + paddingY * 2)))

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            logThrottled("bitmapContextFailed", interval: 5) {
                "[OverlayMetal] bitmap context failed size:\(width)x\(height)"
            }
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        UIGraphicsPushContext(context)
        if config.backgroundEnabled {
            let background = UIColor(overlayHex: config.backgroundColorHex) ?? .black
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            background.withAlphaComponent(CGFloat(config.backgroundOpacity)).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: CGFloat(config.cornerRadius)).fill()
        }
        (text as NSString).draw(at: CGPoint(x: paddingX, y: paddingY), withAttributes: attrs)
        UIGraphicsPopContext()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = MetalContext.shared.device.makeTexture(descriptor: descriptor) else {
            logThrottled("textureCreateFailed", interval: 5) {
                "[OverlayMetal] texture create failed size:\(width)x\(height)"
            }
            return nil
        }
        pixels.withUnsafeBytes {
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: $0.baseAddress!,
                bytesPerRow: width * 4
            )
        }

        let value = (texture: texture, size: CGSize(width: width, height: height))
        textureLock.lock()
        cachedTextureKey = key
        cachedTexture = value
        textureLock.unlock()
        return value
    }

    private func cachedTimeText(config: TimeOverlayConfig) -> String {
        let now = Date()
        let second = Int(now.timeIntervalSince1970)

        textureLock.lock()
        if cachedSecond == second, !cachedText.isEmpty {
            let text = cachedText
            textureLock.unlock()
            return text
        }
        textureLock.unlock()

        let text = timeText(config: config, now: now)
        textureLock.lock()
        cachedSecond = second
        cachedText = text
        textureLock.unlock()
        return text
    }

    private func timeText(config: TimeOverlayConfig, now: Date) -> String {
        switch config.format {
        case .timeOnly, .dateTime:
            formatter.dateFormat = config.format.dateFormat
            return formatter.string(from: now)
        case .elapsed:
            let totalSeconds = max(0, Int(now.timeIntervalSince(startedAt)))
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            let seconds = totalSeconds % 60
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
    }

    private func logThrottled(_ key: String, interval: CFAbsoluteTime = 2, message: () -> String) {
        let now = CFAbsoluteTimeGetCurrent()
        logLock.lock()
        let last = lastLogTimes[key] ?? 0
        guard now - last >= interval else {
            logLock.unlock()
            return
        }
        lastLogTimes[key] = now
        logLock.unlock()
        sendlog(message: message())
    }

    private func recordOverlayDuration(start: CFAbsoluteTime) {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsedMs = (now - start) * 1000

        logLock.lock()
        overlayFrameCount += 1
        let frame = overlayFrameCount
        let shouldLog = frame % 120 == 0 && now - lastOverlayDurationLogTime >= 2
        if shouldLog {
            lastOverlayDurationLogTime = now
        }
        logLock.unlock()

        guard shouldLog else { return }
        sendlog(message: "[OverlayMetal] cpu cost \(String(format: "%.3f", elapsedMs))ms frame:\(frame)")
    }
}

private struct OverlayCompositeParams {
    var originX: UInt32
    var originY: UInt32
    var overlayWidth: UInt32
    var overlayHeight: UInt32
    var dstWidth: UInt32
    var dstHeight: UInt32
    var opacity: Float
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
        guard raw.count == 6, let value = Int(raw, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xff) / 255.0,
            green: CGFloat((value >> 8) & 0xff) / 255.0,
            blue: CGFloat(value & 0xff) / 255.0,
            alpha: 1.0
        )
    }
}
