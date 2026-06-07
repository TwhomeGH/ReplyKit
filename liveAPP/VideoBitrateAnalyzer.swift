import AVFoundation
import UniformTypeIdentifiers

struct VideoAnalysisResult: Identifiable {
    let id = UUID()
    let url: URL
    let fileName: String
    let fileSize: Int64
    let duration: TimeInterval

    struct TrackInfo: Identifiable {
        let id = UUID()
        let mediaType: AVMediaType
        let bitrate: Double
        let codec: String
        let resolution: CGSize?
        let frameRate: Float?
        let audioSampleRate: Double?
        let audioChannels: Int?
    }

    let videoTracks: [TrackInfo]
    let audioTracks: [TrackInfo]

    var averageBitrate: Double {
        guard duration > 0 else { return 0.0 }
        return (Double(fileSize) * 8) / duration
    }

    struct BitrateSample: Identifiable {
        let id = UUID()
        let time: TimeInterval
        let bitrate: Double
    }

    let bitrateSamples: [BitrateSample]

    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    var formattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: duration) ?? "00:00:00"
    }

    var formattedAverageBitrate: String {
        let kbps = averageBitrate / 1000
        if kbps > 1000 {
            return String(format: "%.2f Mbps", kbps / 1000)
        }
        return String(format: "%.0f Kbps", kbps)
    }

    var estimatedMaxBitrate: Double {
        videoTracks.map(\.bitrate).max() ?? averageBitrate
    }
}

actor VideoBitrateAnalyzer {

    static func analyze(url: URL) async -> VideoAnalysisResult? {
        let asset = AVAsset(url: url)

        guard let duration = try? await asset.load(.duration) else { return nil }
        let durationSec = CMTimeGetSeconds(duration)
        guard durationSec > 0 else { return nil }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            ?? (try? url.resourceValues(forKeys: [.totalFileSizeKey]).totalFileSize)
            ?? 0

        let fileName = url.lastPathComponent

        let tracks = try? await asset.loadTracks(withMediaType: .video)
        let audioTracks = try? await asset.loadTracks(withMediaType: .audio)

        var videoInfos: [VideoAnalysisResult.TrackInfo] = []
        var audioInfos: [VideoAnalysisResult.TrackInfo] = []

        if let tracks = tracks {
            for track in tracks {
                let formatDesc = try? await track.load(.formatDescriptions)
                let codec = formatDesc?.first.flatMap { desc -> String in
                    let fourCC = CMFormatDescriptionGetMediaSubType(desc)
                    return codecString(from: fourCC)
                } ?? "Unknown"

                let naturalSize = try? await track.load(.naturalSize)
                let prefTransform = try? await track.load(.preferredTransform)
                let frameRate = try? await track.load(.nominalFrameRate)

                let correctedSize = naturalSize.map { size in
                    let isPortrait = (prefTransform?.a == 0 && prefTransform?.b == 1 && prefTransform?.c == -1 && prefTransform?.d == 0) ||
                                    (prefTransform?.a == 0 && prefTransform?.b == -1 && prefTransform?.c == 1 && prefTransform?.d == 0)
                    if isPortrait {
                        return CGSize(width: size.height, height: size.width)
                    }
                    return size
                }

                let bitrate = try? await track.load(.estimatedDataRate)

                videoInfos.append(VideoAnalysisResult.TrackInfo(
                    mediaType: .video,
                    bitrate: bitrate.map(Double.init) ?? 0.0,
                    codec: codec,
                    resolution: correctedSize,
                    frameRate: frameRate ?? Float(0.0),
                    audioSampleRate: nil,
                    audioChannels: nil
                ))
            }
        }

        if let audioTracks = audioTracks {
            for track in audioTracks {
                let formatDesc = try? await track.load(.formatDescriptions)
                let codec = formatDesc?.first.flatMap { desc -> String in
                    let fourCC = CMFormatDescriptionGetMediaSubType(desc)
                    return codecString(from: fourCC)
                } ?? "AAC"

                let bitrate = try? await track.load(.estimatedDataRate)
                let sampleRate = try? await track.load(.naturalTimeScale)
                let format = formatDesc?.first
                var channels: Int? = nil
                if let format = format {
                    let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)
                    channels = basic.map { Int($0.pointee.mChannelsPerFrame) }
                }

                audioInfos.append(VideoAnalysisResult.TrackInfo(
                    mediaType: .audio,
                    bitrate: bitrate.map(Double.init) ?? 0.0,
                    codec: codec,
                    resolution: nil,
                    frameRate: nil,
                    audioSampleRate: Double(sampleRate ?? 0),
                    audioChannels: channels
                ))
            }
        }

        let samples = await extractBitrateSamples(asset: asset, duration: durationSec)

        return VideoAnalysisResult(
            url: url,
            fileName: fileName,
            fileSize: Int64(fileSize),
            duration: durationSec,
            videoTracks: videoInfos,
            audioTracks: audioInfos,
            bitrateSamples: samples
        )
    }

    private static func extractBitrateSamples(asset: AVAsset, duration: TimeInterval) async -> [VideoAnalysisResult.BitrateSample] {
        guard let assetReader = try? AVAssetReader(asset: asset) else { return [] }
        guard let videoTrack = (try? await asset.loadTracks(withMediaType: .video))?.first else { return [] }

        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        guard assetReader.canAdd(output) else { return [] }
        assetReader.add(output)
        assetReader.startReading()

        let segmentCount = min(Int(duration), 100)
        let segmentDuration = duration / Double(segmentCount)
        var segments = [Int64](repeating: 0, count: segmentCount)

        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let sec = CMTimeGetSeconds(time)
            let idx = min(Int(sec / segmentDuration), segmentCount - 1)
            if idx >= 0 && idx < segmentCount {
                segments[idx] += Int64(CMSampleBufferGetTotalSampleSize(sample))
            }
        }

        assetReader.cancelReading()

        return segments.enumerated().compactMap { (i, bytes) in
            guard bytes > 0 else { return nil }
            let time = Double(i) * segmentDuration
            let bitrate = Double(bytes) * 8 / segmentDuration
            return VideoAnalysisResult.BitrateSample(time: time, bitrate: bitrate)
        }
    }

    private static func codecString(from fourCC: FourCharCode) -> String {
        switch fourCC {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC (H.265)"
        case kCMVideoCodecType_HEVCWithAlpha: return "HEVC Alpha"
        case kCMVideoCodecType_MPEG4Video: return "MPEG-4"
        case kCMVideoCodecType_MPEG2Video: return "MPEG-2"
        case kCMVideoCodecType_JPEG: return "JPEG"
        case kCMVideoCodecType_AppleProRes422: return "ProRes 422"
        case kCMVideoCodecType_AppleProRes4444: return "ProRes 4444"
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatMPEG4AAC_HE: return "HE-AAC"
        case kAudioFormatMPEG4AAC_LD: return "AAC-LD"
        case kAudioFormatMPEG4AAC_ELD: return "AAC-ELD"
        case kAudioFormatOpus: return "Opus"
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatAC3: return "AC-3"
        case kAudioFormatMPEGLayer3: return "MP3"
        default:
            let cString: [CChar] = [
                CChar((fourCC >> 24) & 0xFF),
                CChar((fourCC >> 16) & 0xFF),
                CChar((fourCC >> 8) & 0xFF),
                CChar(fourCC & 0xFF),
                0
            ]
            return String(cString: cString)
        }
    }
}
