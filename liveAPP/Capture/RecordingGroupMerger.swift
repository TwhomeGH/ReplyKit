#if os(iOS)
import Foundation
@preconcurrency import AVFoundation

extension RecordingLibrary {
    /// 依序號合併完成片段，保留各音軌在片段內的時間偏移與所有來源檔案。
    /// - Parameter group: 原始片段共用的群組 ID。
    /// - Returns: 已驗證的新錄影 ID。
    /// - Throws: 群組不完整、格式不一致、檔案讀取或匯出失敗。
    @discardableResult
    func merge(group: UUID) async throws -> UUID {
        func failure(_ text: String) -> NSError {
            NSError(domain: "RecordingMerge", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
        }
        guard beginMerge(group) else { throw failure("此群組已在合併中。") }
        defer { endMerge(group) }
        guard let source = RecordingGroup.make(recordings).first(where: { $0.id == group }), source.canMerge else {
            throw failure("需要至少兩個已完成且序號連續的片段，才能合併。")
        }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw failure("無法建立合併軌道。")
        }
        var cursor = CMTime.zero
        var expectedSize: CGSize?
        var expectedTransform: CGAffineTransform?
        var expectedCodec: FourCharCode?
        var expectedAudioFormat: String?
        var hasAudio = false
        for item in source.segments.sorted(by: { ($0.segmentNumber ?? 0) < ($1.segmentNumber ?? 0) }) {
            let asset = AVURLAsset(url: fileURL(for: item.id))
            let duration = try await asset.load(.duration)
            guard duration.seconds.isFinite, duration.seconds > 0,
                  let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw failure("片段 \(item.segmentNumber ?? 0) 缺少有效視訊。")
            }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let formats = try await track.load(.formatDescriptions)
            guard let format = formats.first else { throw failure("無法讀取片段編碼格式。") }
            let codec = CMFormatDescriptionGetMediaSubType(format)
            if let expectedSize, let expectedTransform, let expectedCodec {
                guard size == expectedSize, transform == expectedTransform, codec == expectedCodec else {
                    throw failure("片段尺寸、方向或編碼不同，無法直接合併。")
                }
            } else {
                expectedSize = size
                expectedTransform = transform
                expectedCodec = codec
                video.preferredTransform = transform
            }
            let range = CMTimeRange(start: .zero, duration: duration)
            let videoRange = CMTimeRangeGetIntersection(try await track.load(.timeRange), range)
            try video.insertTimeRange(videoRange, of: track, at: cursor + videoRange.start)
            if let sound = try await asset.loadTracks(withMediaType: .audio).first {
                let descriptions = try await sound.load(.formatDescriptions)
                guard let description = descriptions.first,
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
                    throw failure("片段缺少有效音訊格式。")
                }
                let signature = "\(asbd.pointee.mFormatID)/\(asbd.pointee.mSampleRate)/\(asbd.pointee.mChannelsPerFrame)"
                if let expectedAudioFormat, signature != expectedAudioFormat {
                    throw failure("片段音訊格式不同，無法直接合併。")
                }
                expectedAudioFormat = signature
                hasAudio = true
                // 音訊可能晚於畫面開始；插入原始偏移，不把聲音提前。
                let audioRange = CMTimeRangeGetIntersection(try await sound.load(.timeRange), range)
                if audioRange.duration > .zero {
                    try audio.insertTimeRange(audioRange, of: sound, at: cursor + audioRange.start)
                }
            }
            cursor = cursor + duration
        }
        let result = try create()
        do {
            try identifyMerged(result.id, group: group)
            update(result.id, phase: .finishing, duration: cursor.seconds, bytes: 0, message: "正在合併，原片段保留。")
            guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
                  exporter.supportedFileTypes.contains(.mp4) else { throw failure("此組片段不支援直接合併為 MP4。") }
            let destination = fileURL(for: result.id)
            exporter.outputURL = destination
            exporter.outputFileType = .mp4
            await exporter.export()
            guard exporter.status == .completed else { throw exporter.error ?? failure("合併匯出失敗。") }
            let output = AVURLAsset(url: destination)
            let duration = try await output.load(.duration)
            guard try await output.load(.isPlayable), duration.seconds.isFinite,
                  abs(duration.seconds - cursor.seconds) < 0.5,
                  !(try await output.loadTracks(withMediaType: .video)).isEmpty else {
                throw failure("合併結果驗證失敗，原片段仍保留。")
            }
            if hasAudio, try await output.loadTracks(withMediaType: .audio).isEmpty {
                throw failure("合併結果缺少音訊，原片段仍保留。")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            guard let bytes = (attributes[.size] as? NSNumber)?.int64Value, bytes > 0 else {
                throw failure("合併產物大小無效。")
            }
            update(result.id, phase: .ready, duration: duration.seconds, bytes: bytes, message: "整場合併影片；原片段已保留。")
            sendlog(message: "[RecordingMerge] group=\(group) output=\(result.id) segments=\(source.segmentCount) bytes=\(bytes)")
            return result.id
        } catch {
            update(result.id, phase: .failed, duration: 0, bytes: 0, message: error.localizedDescription)
            errorMessage = "合併失敗：" + error.localizedDescription
            sendlog(message: "[RecordingMerge] group=\(group) failed=\(error)")
            throw error
        }
    }
}
#endif
