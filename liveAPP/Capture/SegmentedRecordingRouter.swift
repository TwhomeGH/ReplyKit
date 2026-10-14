#if os(iOS)
import Foundation
@preconcurrency import AVFoundation

/// 依 PTS 分配片段；舊段短暫保留以接收晚到音訊，收尾另行執行。
/// 只有 sink 的單一消費工作呼叫 append／finish；不可從多個工作並行呼叫。
actor SegmentedRecordingWriter {
    let group = UUID()
    private let settings: DirectRecordingSettings
    private let library: RecordingLibrary
    private var current: RecordingSegmentWriter?
    private var previous: RecordingSegmentWriter?
    private var boundary: CMTime = .invalid
    private var retireAt: ContinuousClock.Instant?
    private var finalizing: Task<Void, Error>?
    private var number = 0
    private var lateAudio = 0

    /// 設定與錄製庫在整場錄影共用，片段序號由本路由器配置。
    init(settings: DirectRecordingSettings, library: RecordingLibrary) {
        self.settings = settings
        self.library = library
    }

    /// 路由影音樣本；晚到音訊可在六秒寬限內回到上一段。
    /// - Parameter sample: 共用 host time 時間軸上的 PCM 或視訊樣本。
    /// - Throws: 開段、寫入或先前收尾錯誤。
    func append(_ sample: CMSampleBuffer) async throws {
        let pts = sample.presentationTimeStamp
        guard pts.seconds.isFinite else { return }
        let isVideo = sample.imageBuffer != nil
        if let retireAt, ContinuousClock.now >= retireAt { retirePrevious() }
        if isVideo && (current == nil || pts.seconds - boundary.seconds >= settings.segmentSeconds) {
            // 至多保留一個收尾工作；異常慢的磁碟不能造成無限累積 Writer。
            if let finalizing { try await finalizing.value; self.finalizing = nil }
            if previous != nil {
                retirePrevious()
                if let finalizing { try await finalizing.value; self.finalizing = nil }
            }
            previous = current
            boundary = pts
            retireAt = previous == nil ? nil : ContinuousClock.now.advanced(by: .seconds(6))
            number += 1
            current = RecordingSegmentWriter(settings: settings, library: library, group: group, number: number)
            sendlog(message: "[RecordingBoundary] group=\(group) segment=\(number) boundaryPTS=\(pts.seconds) graceSeconds=6")
        }
        if !isVideo && boundary.isValid && pts < boundary {
            if let previous {
                if sample.duration.seconds.isFinite, sample.duration.seconds > 0,
                   pts + sample.duration > boundary {
                    // PCM 緩衝跨越邊界時按取樣數切開，不能整塊留在舊段後被截斷。
                    let count = CMSampleBufferGetNumSamples(sample)
                    let split = min(count, max(0, Int(ceil((boundary - pts).seconds / sample.duration.seconds * Double(count)))))
                    if split > 0 { try await previous.append(slice(sample, start: 0, count: split)) }
                    if split < count { try await current?.append(slice(sample, start: split, count: count - split)) }
                } else {
                    try await previous.append(sample)
                }
            } else {
                lateAudio += 1
                if lateAudio == 1 || lateAudio % 100 == 0 {
                    sendlog(message: "[RecordingBoundary] group=\(group) lateAudioDropped=\(lateAudio) pts=\(pts.seconds) boundary=\(boundary.seconds)")
                }
            }
            return
        }
        try await current?.append(sample)
    }

    /// 複製指定 PCM 取樣範圍，CoreMedia 保留該範圍的時間戳。
    /// - Parameters:
    ///   - sample: 來源 PCM 樣本。
    ///   - start: 起始取樣索引。
    ///   - count: 要保留的取樣數。
    /// - Returns: 只包含該範圍的樣本緩衝。
    /// - Throws: CoreMedia 無法建立子範圍。
    private func slice(_ sample: CMSampleBuffer, start: Int, count: Int) throws -> CMSampleBuffer {
        var result: CMSampleBuffer?
        let status = CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault,
            sampleBuffer: sample, sampleRange: CFRange(location: start, length: count), sampleBufferOut: &result)
        guard status == noErr, let result else {
            throw NSError(domain: "RecordingBoundary", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "無法切分跨段音訊樣本。"])
        }
        return result
    }

    /// 停止舊段接收，交給獨立工作完成；新段仍可消費樣本。
    private func retirePrevious() {
        guard let previous else { return }
        let end = boundary
        self.previous = nil
        retireAt = nil
        finalizing = Task {
            do { try await previous.finishSegment(at: end) }
            catch { await previous.failed(error); throw error }
        }
    }

    /// 停止時等待所有已接受樣本所屬的片段收尾。
    /// - Throws: 任一片段收尾失敗。
    func finishSegment() async throws {
        if let finalizing { try await finalizing.value; self.finalizing = nil }
        retirePrevious()
        if let finalizing { try await finalizing.value; self.finalizing = nil }
        try await current?.finishSegment()
    }

    /// 中止仍開啟的片段，等待已開始的收尾工作；錯誤由各段保留日誌。
    func failed(_ error: Error) async {
        await current?.failed(error)
        await previous?.failed(error)
        if let finalizing {
            do { try await finalizing.value }
            catch { sendlog(message: "[RecordingBoundary] finalizationFailed=\(error)") }
        }
    }
}
#endif
