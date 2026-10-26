#if os(iOS)
import Foundation
@preconcurrency import AVFoundation

/// 平均碼率使用 Reader／Writer；系統品質使用 ExportSession。兩者可接方向 composition。
/// 原檔只在成功驗證且輸出較小時替換；取消、讀寫失敗與無節省都保留原檔。
enum RecordingTranscoder {
    /// 手動轉碼的音訊處理；保留模式僅接受 MP4 相容的 AAC。
    enum AudioMode: String, CaseIterable, Sendable { case preserve, aac, remove }
    /// 系統品質預設；不是固定畫質百分比，也不保證縮小檔案。
    enum QualityPreset: String, CaseIterable, Sendable {
        case low, medium, highest, hevcHighest

        var name: String {
            switch self {
            case .low: return AVAssetExportPresetLowQuality
            case .medium: return AVAssetExportPresetMediumQuality
            case .highest: return AVAssetExportPresetHighestQuality
            case .hevcHighest: return AVAssetExportPresetHEVCHighestQuality
            }
        }

        var title: String {
            switch self {
            case .low: return "系統低品質"
            case .medium: return "系統中品質"
            case .highest: return "系統最高品質"
            case .hevcHighest: return "HEVC 最高品質"
            }
        }
    }

    /// 每個錄影 UUID 有獨立暫存路徑，供低頻率容量取樣。
    static func temporaryURL(for url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("compressed.mp4") }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "RecordingCompression", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// 以階段名稱包裝底層錯誤，保留原始錯誤供除錯與日誌辨識。
    private static func staged(_ stage: String, _ error: Error) -> NSError {
        NSError(domain: "RecordingCompression", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "\(stage)：\(error.localizedDescription)",
            NSUnderlyingErrorKey: error
        ])
    }

    /// 平均碼率模式直接複製 AAC；系統品質模式由匯出預設管理影音編碼。
    /// - Parameters:
    ///   - url: 原始錄影位置；僅在產物驗證通過且較小時替換。
    ///   - asset: 原始媒體，或已套用方向矩陣的 composition。
    ///   - videoComposition: 多段方向修正；未提供時保留軌道方向矩陣。
    ///   - settings: 本次工作固定的壓縮參數。
    ///   - destination: 手動壓縮的新 MP4 路徑；nil 保留原有較小才替換錄影的行為。
    ///   - audioMode: 保留 AAC、轉 AAC 或移除音訊。
    ///   - audioBitrate: 轉 AAC 的每軌碼率，單位 bps，範圍 32000…320000。
    ///   - qualityPreset: 手動另存的系統品質預設；須搭配 systemQuality，其他手動影音參數不套用。
    ///   - progress: 低頻媒體處理進度；1 表示產物驗證並移入正式位置。
    /// - Returns: 包含編碼、像素尺寸、目標碼率及節省比例的結果文字。
    /// - Throws: 取消、格式不支援、讀寫或驗證失敗；原檔保留。
    static func compress(url: URL, asset: AVAsset, videoComposition: AVVideoComposition? = nil,
                         settings: RecordingCompressionSettings, destination: URL? = nil,
                         audioMode: AudioMode = .preserve, audioBitrate: Int = 128000,
                         qualityPreset: QualityPreset? = nil,
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        try Task.checkCancellation()
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard videoTracks.count == 1, let track = videoTracks.first else {
            throw failure("壓縮模式需要一條視訊軌。")
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard let format = descriptions.first else { throw failure("無法取得視訊格式。") }
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String ?? ""
        guard !transfer.contains("2084"), !transfer.uppercased().contains("HLG") else {
            throw failure("HDR 錄影暫不支援此壓縮模式。")
        }
        let naturalSize = try await track.load(.naturalSize)
        let sourceSize = videoComposition?.renderSize ?? naturalSize
        guard sourceSize.width.isFinite, sourceSize.height.isFinite, sourceSize.width > 0, sourceSize.height > 0 else {
            throw failure("錄影尺寸無效。")
        }
        guard (32000...320000).contains(audioBitrate) else { throw failure("AAC 碼率超出範圍。") }
        if let box = settings.boundingSize {
            guard box.width.isFinite, box.height.isFinite,
                  (2...8192).contains(box.width), (2...8192).contains(box.height) else {
                throw failure("自訂寬高必須介於 2…8192 px。")
            }
        }
        let sourceTransform = try await track.load(.preferredTransform)
        // 設定採觀看方向；直向影片常以橫向像素搭配旋轉矩陣儲存。
        let swapsAxes = videoComposition == nil && abs(sourceTransform.b) > abs(sourceTransform.a)
        let size = settings.outputSize(sourceSize, swapsAxes: swapsAxes)
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw failure("錄影時長無效。") }
        let originalBytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if let destination {
            guard destination.standardizedFileURL != url.standardizedFileURL,
                  !FileManager.default.fileExists(atPath: destination.path) else {
                throw failure("手動壓縮需要新的輸出路徑。")
            }
        }
        if settings.systemQuality {
            return try await exportSystemQuality(url: url, asset: asset, composition: videoComposition,
                settings: settings, originalBytes: originalBytes, duration: duration,
                destination: destination, qualityPreset: qualityPreset)
        }
        // 平均碼率只能估算；另保留音訊及容器空間，寫入時仍須處理磁碟不足。
        let estimatedBytes = duration.seconds * Double(settings.videoBitrate + 1_000_000) / 8 + 64_000_000
        if let free = try? (destination ?? url).deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           Double(free) < estimatedBytes {
            throw failure("可用空間不足以安全產生壓縮暫存檔。")
        }
        let temporary = destination.map { _ in FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".partial.mp4") } ?? temporaryURL(for: url)
        let reader = try AVAssetReader(asset: asset)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4) }
        catch { throw staged("無法建立壓縮暫存檔", error) }
        defer {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: temporary)
        }
        let pixelSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        let videoOutput: AVAssetReaderOutput
        if let videoComposition {
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: pixelSettings)
            output.videoComposition = videoComposition
            videoOutput = output
        } else {
            videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: pixelSettings)
        }
        videoOutput.alwaysCopiesSampleData = false
        let codec: AVVideoCodecType = settings.hevc ? .hevc : .h264
        var outputSettings: [String: Any] = [
            AVVideoCodecKey: codec, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: settings.videoBitrate,
                                               AVVideoMaxKeyFrameIntervalDurationKey: 2,
                                               // 與錄影路徑一致關閉 B 幀：影格時間順序固定，輸出時長與驗證較可預期。
                                               AVVideoAllowFrameReorderingKey: false] as [String: Any]
        ]
        var colors: [String: Any] = [:]
        for (source, destination) in [(kCMFormatDescriptionExtension_ColorPrimaries, AVVideoColorPrimariesKey),
                                       (kCMFormatDescriptionExtension_TransferFunction, AVVideoTransferFunctionKey),
                                       (kCMFormatDescriptionExtension_YCbCrMatrix, AVVideoYCbCrMatrixKey)] {
            if let value = extensions[source as String] as? String { colors[destination] = value }
        }
        if !colors.isEmpty { outputSettings[AVVideoColorPropertiesKey] = colors }
        guard writer.canApply(outputSettings: outputSettings, forMediaType: .video) else {
            throw failure("此裝置不支援所選壓縮設定。")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        videoInput.expectsMediaDataInRealTime = false
        if videoComposition == nil {
            let transform = try await track.load(.preferredTransform)
            // 在縮小後的像素座標重新正規化旋轉／鏡像矩陣，避免平移量仍使用原尺寸。
            let linear = CGAffineTransform(a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: 0, ty: 0)
            let bounds = CGRect(origin: .zero, size: size).applying(linear)
            videoInput.transform = linear.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        }
        var outputs: [AVAssetReaderOutput] = [videoOutput]
        var inputs: [AVAssetWriterInput] = [videoInput]
        let audioTracks = audioMode == .remove ? [] : try await asset.loadTracks(withMediaType: .audio)
        for audio in audioTracks {
            guard let hint = try await audio.load(.formatDescriptions).first else {
                throw failure("無法讀取音訊格式。")
            }
            if audioMode == .preserve && CMFormatDescriptionGetMediaSubType(hint) != kAudioFormatMPEG4AAC {
                throw failure("保留音軌僅支援 AAC；請改選轉 AAC 或移除音訊。")
            }
            let decode: [String: Any]? = audioMode == .aac ? [AVFormatIDKey: kAudioFormatLinearPCM] : nil
            let output = AVAssetReaderTrackOutput(track: audio, outputSettings: decode)
            output.alwaysCopiesSampleData = false
            outputs.append(output)
            if audioMode == .aac {
                guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(hint)?.pointee,
                      asbd.mChannelsPerFrame > 0, asbd.mChannelsPerFrame <= 2 else {
                    throw failure("轉 AAC 目前支援單聲道或雙聲道音訊。")
                }
                let encode: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000, AVNumberOfChannelsKey: asbd.mChannelsPerFrame,
                    AVEncoderBitRateKey: audioBitrate]
                guard writer.canApply(outputSettings: encode, forMediaType: .audio) else {
                    throw failure("裝置無法使用此 AAC 設定。")
                }
                inputs.append(AVAssetWriterInput(mediaType: .audio, outputSettings: encode))
            } else {
                inputs.append(AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint))
            }
        }
        for index in inputs.indices {
            guard reader.canAdd(outputs[index]), writer.canAdd(inputs[index]) else { throw failure("無法建立錄影轉碼軌道。") }
            reader.add(outputs[index]); writer.add(inputs[index])
        }
        guard writer.startWriting() else { throw staged("無法開始寫入壓縮檔", writer.error ?? failure("寫入器未回報原因。")) }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { throw reader.error ?? failure("無法開始讀取。") }
        var lastProgress = -Double.infinity
        var finished = Set<Int>()
        var limiter = RecordingFrameRateLimiter(limit: settings.fpsLimit)
        // 有背壓才短暫讓出執行；不堆積整段影片或阻塞主執行緒。
        while finished.count < inputs.count {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw staged("壓縮寫入中止", writer.error ?? failure("寫入中止。")) }
            var advanced = false
            for index in inputs.indices where !finished.contains(index) && inputs[index].isReadyForMoreMediaData {
                guard let sample = outputs[index].copyNextSampleBuffer() else {
                    if reader.status == .failed { throw reader.error ?? failure("讀取失敗。") }
                    inputs[index].markAsFinished(); finished.insert(index); continue
                }
                advanced = true
                if index == 0 {
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    guard pts.isFinite else { throw failure("影片時間戳無效。") }
                    if pts - lastProgress >= 0.25 {
                        progress?(min(0.99, max(0, pts / duration.seconds)))
                        lastProgress = pts
                    }
                    if !limiter.accepts(seconds: pts) { continue }
                }
                guard inputs[index].append(sample) else { throw staged("無法寫入媒體樣本", writer.error ?? failure("無法寫入媒體樣本。")) }
            }
            if !advanced { try await Task.sleep(nanoseconds: 2_000_000) }
        }
        guard reader.status == .completed else { throw reader.error ?? failure("來源尚未完整讀取。") }
        await withTaskCancellationHandler {
            await writer.finishWriting()
        } onCancel: { writer.cancelWriting() }
        try Task.checkCancellation()
        guard writer.status == .completed else { throw staged("轉碼未完成", writer.error ?? failure("轉碼未完成。")) }
        let outputBytes = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let check = AVURLAsset(url: temporary)
        let outputDuration = try await check.load(.duration)
        guard outputBytes > 0, abs(outputDuration.seconds - duration.seconds) < 1,
              try await check.loadTracks(withMediaType: .video).count == 1,
              try await check.loadTracks(withMediaType: .audio).count == inputs.count - 1 else {
            throw failure("壓縮產物驗證失敗，保留原檔。")
        }
        guard destination != nil || outputBytes < originalBytes else { throw failure("壓縮檔未縮小，保留原檔（方向處理亦未套用）。") }
        try Task.checkCancellation()
        if let destination {
            do { try FileManager.default.moveItem(at: temporary, to: destination) }
            catch { throw staged("無法移入壓縮成品", error) }
        } else {
            do { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary) }
            catch { throw staged("無法取代原始錄影", error) }
        }
        progress?(1)
        return "轉碼完成：\(codec.rawValue)、\(Int(size.width))×\(Int(size.height))、目標 \(Double(settings.videoBitrate) / 1_000_000) Mbps，由 \(String(format: "%.1f", Double(originalBytes) / 1_000_000)) MB → \(String(format: "%.1f", Double(outputBytes) / 1_000_000)) MB，節省 \(String(format: "%.1f", Double(originalBytes - outputBytes) / 1_000_000)) MB（\(Int((1 - Double(outputBytes) / Double(originalBytes)) * 100))%）。"
    }
    /// 交由 ExportSession 管理多次讀取；不把多次編碼旗標套在單次 Reader 迴圈。
    private static func exportSystemQuality(url: URL, asset: AVAsset, composition: AVVideoComposition?,
        settings: RecordingCompressionSettings, originalBytes: Int, duration: CMTime,
        destination: URL? = nil, qualityPreset: QualityPreset? = nil) async throws -> String {
        let preset = qualityPreset?.name ?? (settings.hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset),
              exporter.supportedFileTypes.contains(.mp4) else { throw failure("此裝置不支援所選系統品質預設。") }
        let temporary = destination.map { _ in FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".quality.mp4") } ?? temporaryURL(for: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        exporter.outputURL = temporary
        exporter.outputFileType = .mp4
        exporter.videoComposition = composition
        exporter.canPerformMultiplePassesOverSourceMediaData = settings.multiPass
        await withTaskCancellationHandler {
            await exporter.export()
        } onCancel: { exporter.cancelExport() }
        try Task.checkCancellation()
        guard exporter.status == .completed else { throw exporter.error ?? failure("系統品質匯出失敗。") }
        let outputBytes = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let check = AVURLAsset(url: temporary)
        let checkDuration = try await check.load(.duration)
        let expectedAudio = try await asset.loadTracks(withMediaType: .audio).count
        guard outputBytes > 0, (destination != nil || outputBytes < originalBytes),
              abs(checkDuration.seconds - duration.seconds) < 1,
              try await check.loadTracks(withMediaType: .video).count == 1,
              try await check.loadTracks(withMediaType: .audio).count == expectedAudio else {
            throw failure("系統品質產物未縮小或驗證失敗，保留原檔（方向處理亦未套用）。")
        }
        try Task.checkCancellation()
        if let destination {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } else {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        }
        return String(format: "系統高品質匯出完成：%.1f MB → %.1f MB，節省 %.1f MB（%.1f%%）。多次編碼：%@。",
            Double(originalBytes) / 1_000_000, Double(outputBytes) / 1_000_000,
            Double(originalBytes - outputBytes) / 1_000_000,
            Double(originalBytes - outputBytes) / Double(originalBytes) * 100,
            settings.multiPass ? "已請求，由系統決定是否採用" : "未請求")
    }

}
#endif
