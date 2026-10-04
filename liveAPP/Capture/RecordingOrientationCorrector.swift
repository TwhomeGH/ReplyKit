#if os(iOS)
import Foundation
@preconcurrency import AVFoundation
import CoreGraphics

/// 原生錄製完成後才處理，成功以暫存檔取代原檔；失敗時保留原始錄製。
enum RecordingOrientationCorrector {
    static func transform(_ orientation: Int, size: CGSize) -> CGAffineTransform {
        let w = size.width, h = size.height
        switch orientation {
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 6: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case 7: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 8: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        default: return .identity
        }
    }
    static func correct(url: URL, timeline: RecordingOrientationTimeline) async throws -> String {
        try Task.checkCancellation()
        let snapshot = timeline.snapshot()
        guard snapshot.reliable else { return "未取得可靠的影格方向，保留系統原始錄影。" }
        let asset = AVURLAsset(url: url)
        guard let original = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "RecordingOrientation", code: 1)
        }
        let existing = try await original.load(.preferredTransform)
        // 系統若已寫入矩陣，不能再重複套用附件方向。
        guard existing.isIdentity else { return "系統已提供影片方向矩陣，保留原有方向。" }
        let size = try await original.load(.naturalSize)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw NSError(domain: "RecordingOrientation", code: 6)
        }
        let duration = try await asset.load(.duration)
        let videoRange = try await original.load(.timeRange)
        guard duration.seconds.isFinite, duration.seconds > 0,
              videoRange.start.seconds.isFinite, videoRange.duration.seconds.isFinite else {
            throw NSError(domain: "RecordingOrientation", code: 7)
        }
        let videoStart = videoRange.start.seconds
        let events = snapshot.events.filter { $0.seconds < videoRange.duration.seconds }
        guard let first = events.first else { return "沒有可套用的方向時間範圍，保留原始錄影。" }
        if events.count == 1 && first.orientation == 1 { return "影格方向已正確，無需轉正。" }
        let composition = AVMutableComposition()
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        for track in videoTracks + audioTracks {
            guard let copy = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw NSError(domain: "RecordingOrientation", code: 2)
            }
            let range = try await track.load(.timeRange)
            try copy.insertTimeRange(range, of: track, at: range.start)
        }
        guard let video = composition.tracks(withMediaType: .video).first as? AVMutableCompositionTrack else {
            throw NSError(domain: "RecordingOrientation", code: 3)
        }
        let single = events.count == 1
        let preset = single ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
        guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw NSError(domain: "RecordingOrientation", code: 4)
        }
        if single {
            video.preferredTransform = transform(first.orientation, size: size)
        } else {
            // 固定畫布取第一個有效方向；後續方向等比例置中，避免不同方向伸縮失真。
            let firstBounds = CGRect(origin: .zero, size: size).applying(transform(first.orientation, size: size))
            let canvas = CGSize(width: max(2, floor(firstBounds.width / 2) * 2), height: max(2, floor(firstBounds.height / 2) * 2))
            let videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = canvas
            let fps = try await original.load(.nominalFrameRate)
            videoComposition.frameDuration = CMTime(value: 1, timescale: Int32(fps.isFinite && fps > 0 ? max(1, min(60, fps.rounded())) : 60))
            var instructions: [AVVideoCompositionInstructionProtocol] = []
            for (index, event) in events.enumerated() {
                let start = index == 0 ? 0 : videoStart + event.seconds
                let end = index + 1 < events.count ? videoStart + events[index + 1].seconds : duration.seconds
                guard end > start else { continue }
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000), end: CMTime(seconds: end, preferredTimescale: 60000))
                instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
                let rotation = transform(event.orientation, size: size)
                let bounds = CGRect(origin: .zero, size: size).applying(rotation)
                let scale = min(canvas.width / bounds.width, canvas.height / bounds.height)
                let fit = rotation.concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(translationX: (canvas.width - bounds.width * scale) / 2, y: (canvas.height - bounds.height * scale) / 2))
                layer.setTransform(fit, at: instruction.timeRange.start)
                instruction.layerInstructions = [layer]
                instructions.append(instruction)
            }
            videoComposition.instructions = instructions
            exporter.videoComposition = videoComposition
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".orientation.mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        exporter.outputURL = temporary
        exporter.outputFileType = .mp4
        await withTaskCancellationHandler {
            await exporter.export()
        } onCancel: { exporter.cancelExport() }
        try Task.checkCancellation()
        guard exporter.status == .completed else { throw exporter.error ?? NSError(domain: "RecordingOrientation", code: 5) }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        return single ? "已依影格方向轉正（不重新編碼）。" : "已依方向變化轉正（重新編碼）。"
    }
}
#endif
