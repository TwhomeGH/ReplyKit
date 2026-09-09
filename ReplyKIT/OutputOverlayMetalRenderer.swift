import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import Metal
import UIKit

// MARK: - Immutable per-frame snapshot
//
// 設計目標: frame path (applyIfNeeded) 只讀一份不可變 snapshot 再 encode，
// 完全不碰共享 mutable config / texture cache。
// 所有昂貴工作 (config 載入、時間字串、CoreGraphics raster、texture 上傳)
// 都移到位於 producerQueue 的單一 producer；每秒或 config 改變時才重建一次 snapshot。
//
// 並行模型:
//   - stateLock 只保護 snapshot / pipeline / pendingConfig / configVersion /
//     refreshQueued 這些「發布點」欄位,每個 frame 只取一次短 lock。
//   - producerQueue (serial) 是 cache 與 raster 的唯一執行緒,內部不再需要 lock。
//   - Socket queue / Darwin notification 的 apply()/reloadConfig() 只換 config
//     + bump version + 觸發 producer,由 producer 在下次重建時套用最新值。
final class OutputOverlayMetalRenderer: @unchecked Sendable {
    static let shared = OutputOverlayMetalRenderer()

    private struct OverlaySnapshot {
        static let empty = OverlaySnapshot(
            enabled: false,
            timeEnabled: false,
            second: -1,
            texture: nil,
            size: .zero,
            anchor: .topRight,
            marginX: 0,
            marginY: 0,
            offsetX: 0,
            offsetY: 0
        )

        let enabled: Bool
        let timeEnabled: Bool
        let second: Int
        let texture: MTLTexture?
        let size: CGSize
        let anchor: OverlayAnchor
        let marginX: CGFloat
        let marginY: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
    }

    // MARK: - Published state (guarded by stateLock)

    private let stateLock = NSLock()
    private var snapshot = OverlaySnapshot.empty
    private var pipeline: MTLComputePipelineState?
    private var pendingConfig = OverlayConfigStore.load()
    private var configVersion = 0
    private var refreshQueued = false

    // MARK: - Producer-local state (only touched on producerQueue)

    private let producerQueue = DispatchQueue(
        label: "ReplyKit.OutputOverlay.producer",
        qos: .userInitiated
    )
    private var lastProducedSecond = -1
    private var lastProducedVersion = -1

    // MARK: - Diagnostic state

    private let throttleLock = NSLock()
    private let statsLock = NSLock()
    private var overlayFrameCount: UInt64 = 0
    private var lastOverlayDurationLogTime: CFAbsoluteTime = 0
    private var lastMissingCompositeFunctionLogTime: CFAbsoluteTime = 0
    private var lastPipelineFailedLogTime: CFAbsoluteTime = 0
    private var lastBitmapContextFailedLogTime: CFAbsoluteTime = 0
    private var lastTextureCreateFailedLogTime: CFAbsoluteTime = 0

    private let formatter = DateFormatter()
    private let startedAt = Date()

    private init() {
        producerQueue.async { self.runProducer() }
    }

    // MARK: - Frame path (concurrent)

    func applyIfNeeded(commandBuffer: MTLCommandBuffer, dstY: MTLTexture, dstUV: MTLTexture) {
        let access = frameAccess()
        let snap = access.snapshot
        guard snap.enabled, snap.timeEnabled,
              let pipeline = access.pipeline,
              let texture = snap.texture else { return }
        let start = CFAbsoluteTimeGetCurrent()

        requestRefreshIfNeeded(currentSecond: snap.second)

        let canvas = CGSize(width: dstY.width, height: dstY.height)
        let origin = snap.anchor.origin(
            container: canvas,
            item: snap.size,
            marginX: snap.marginX,
            marginY: snap.marginY,
            offsetX: snap.offsetX,
            offsetY: snap.offsetY
        )

        var params = OverlayCompositeParams(
            originX: UInt32(max(0, Int(origin.x.rounded()))),
            originY: UInt32(max(0, Int(origin.y.rounded()))),
            overlayWidth: UInt32(max(0, Int(snap.size.width.rounded()))),
            overlayHeight: UInt32(max(0, Int(snap.size.height.rounded()))),
            dstWidth: UInt32(dstY.width),
            dstHeight: UInt32(dstY.height),
            opacity: 1.0
        )

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        encoder.label = "ReplyKit.output.overlay"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(dstY, index: 1)
        encoder.setTexture(dstUV, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<OverlayCompositeParams>.stride, index: 0)

        let tgWidth = pipeline.threadExecutionWidth
        let tgHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / tgWidth)
        encoder.dispatchThreads(
            MTLSize(width: texture.width, height: texture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tgWidth, height: tgHeight, depth: 1)
        )
        encoder.endEncoding()
        recordOverlayDuration(start: start)
    }

    /// 一次鎖內取出 frame path 需要的全部資源。pipeline 由 producer 建立,
    /// 此處只做純讀取。
    private func frameAccess() -> (snapshot: OverlaySnapshot, pipeline: MTLComputePipelineState?) {
        stateLock.lock()
        let result = (snapshot: snapshot, pipeline: pipeline)
        stateLock.unlock()
        return result
    }

    /// 每秒只會觸發一次 producer 重建 snapshot;frame 本身永遠用舊 snapshot 繼續 render。
    private func requestRefreshIfNeeded(currentSecond: Int) {
        let nowSecond = Int(Date().timeIntervalSince1970)
        guard nowSecond != currentSecond else { return }

        stateLock.lock()
        defer { stateLock.unlock() }
        guard refreshQueued == false else { return }
        refreshQueued = true
        producerQueue.async { self.runProducer() }
    }

    // MARK: - Config writers (Socket queue / Darwin notification)

    func reloadConfig() {
        let config = OverlayConfigStore.load()
        applyInternal(config: config)
        sendlog(message: "[OverlayMetal] reloadConfig enabled:\(config.enabled) time:\(config.time.enabled)")
    }

    func apply(config: OverlaySceneConfig, persist: Bool = true) {
        if persist {
            OverlayConfigStore.save(config)
        }
        applyInternal(config: config)
        sendlog(message: "[OverlayMetal] config applied enabled:\(config.enabled) time:\(config.time.enabled)")
    }

    private func applyInternal(config: OverlaySceneConfig) {
        stateLock.lock()
        pendingConfig = config
        configVersion += 1
        stateLock.unlock()
        producerQueue.async { self.runProducer() }
    }

    // MARK: - Producer (serial; owns cache + raster)

    /// 執行在 producerQueue。循環重建直到 snapshot 對齊「最新 config version +
    /// 當前秒」,若 producer 執行期間又來了新 apply() 會在下一次迭代套用。
    private func runProducer() {
        while true {
            stateLock.lock()
            let config = pendingConfig
            let version = configVersion
            stateLock.unlock()

            guard config.enabled, config.time.enabled else {
                publish(snapshot: .empty, version: version, second: -1)
                finishRefreshCycle()
                return
            }

            let second = Int(Date().timeIntervalSince1970)
            if lastProducedVersion == version, lastProducedSecond == second {
                finishRefreshCycle()
                return
            }

            ensurePipeline()
            let newSnapshot = buildSnapshot(config: config, second: second)
            publish(snapshot: newSnapshot, version: version, second: second)
        }
    }

    /// Producer 專用:序列執行緒上建立 pipeline(僅一次)。失敗時 frame path 會
    /// 因為 pipeline == nil 而跳過 overlay。
    private func ensurePipeline() {
        stateLock.lock()
        let hasPipeline = pipeline != nil
        stateLock.unlock()
        if hasPipeline { return }

        do {
            guard let function = MetalContext.shared.library.makeFunction(name: "compositeOverlayBGRAToNV12") else {
                logThrottled(last: &lastMissingCompositeFunctionLogTime, interval: 5) {
                    "[OverlayMetal] compositeOverlayBGRAToNV12 not found"
                }
                return
            }
            let state = try MetalContext.shared.device.makeComputePipelineState(function: function)
            stateLock.lock()
            if pipeline == nil {
                pipeline = state
            }
            stateLock.unlock()
        } catch {
            logThrottled(last: &lastPipelineFailedLogTime, interval: 5) {
                "[OverlayMetal] pipeline failed: \(error.localizedDescription)"
            }
        }
    }

    private func finishRefreshCycle() {
        stateLock.lock()
        refreshQueued = false
        stateLock.unlock()
    }

    private func publish(snapshot newSnapshot: OverlaySnapshot, version: Int, second: Int) {
        stateLock.lock()
        snapshot = newSnapshot
        stateLock.unlock()
        lastProducedVersion = version
        lastProducedSecond = second
    }

    private func buildSnapshot(config: OverlaySceneConfig, second: Int) -> OverlaySnapshot {
        let timeCfg = config.time
        let base = OverlaySnapshot(
            enabled: true,
            timeEnabled: true,
            second: second,
            texture: nil,
            size: .zero,
            anchor: timeCfg.anchor,
            marginX: CGFloat(timeCfg.marginX),
            marginY: CGFloat(timeCfg.marginY),
            offsetX: CGFloat(timeCfg.offsetX),
            offsetY: CGFloat(timeCfg.offsetY)
        )
        guard let item = rasterizeTimeTexture(config: timeCfg, second: second) else {
            return base
        }
        return OverlaySnapshot(
            enabled: true,
            timeEnabled: true,
            second: second,
            texture: item.texture,
            size: item.size,
            anchor: base.anchor,
            marginX: base.marginX,
            marginY: base.marginY,
            offsetX: base.offsetX,
            offsetY: base.offsetY
        )
    }

    private func rasterizeTimeTexture(config: TimeOverlayConfig, second: Int) -> (texture: MTLTexture, size: CGSize)? {
        let now = Date(timeIntervalSince1970: TimeInterval(second))
        let text = timeText(config: config, now: now)

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
            logThrottled(last: &lastBitmapContextFailedLogTime, interval: 5) {
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
            logThrottled(last: &lastTextureCreateFailedLogTime, interval: 5) {
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

        return (texture, CGSize(width: width, height: height))
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

    // MARK: - Diagnostics

    private func logThrottled(last: inout CFAbsoluteTime, interval: CFAbsoluteTime = 2, message: () -> String) {
        throttleLock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        guard now - last >= interval else {
            throttleLock.unlock()
            return
        }
        last = now
        throttleLock.unlock()
        sendlog(message: message())
    }

    private func recordOverlayDuration(start: CFAbsoluteTime) {
        statsLock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        let elapsedMs = (now - start) * 1000

        overlayFrameCount += 1
        let frame = overlayFrameCount
        let shouldLog = frame % 120 == 0 && now - lastOverlayDurationLogTime >= 2
        if shouldLog {
            lastOverlayDurationLogTime = now
        }
        statsLock.unlock()

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
        guard raw.count == 6, let value = UInt64(raw, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((value & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(value & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }
}
