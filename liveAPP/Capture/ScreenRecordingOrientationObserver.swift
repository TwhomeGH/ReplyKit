#if os(iOS) && SCREEN_CAPTURE_KIT_IOS27 && canImport(ScreenCaptureKit) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
import Foundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation

@available(iOS 27.0, *)
final class ScreenRecordingOrientationObserver: NSObject, SCStreamOutput, @unchecked Sendable {
    let timeline = RecordingOrientationTimeline()
    // 只從 source 的序列 sampleQueue 存取。
    private var lastOrientation: Int?
    private var loggedMissing = false
    private let frameLock = NSLock()
    private var frameCount = 0
    private var firstPTS: Double?
    private var lastPTS: Double?
    private var maxFrameGap: Double = 0
    private var maxFrameGapAtPTS: Double?
    private var lastFrameGap: Double?
    private var frameGapsOver100ms = 0
    private var lastArrival: Double?

    /// 原生 SCRecordingOutput 路徑沒有 ScreenSamplePump；由這個 observer 提供
    /// 影片 frame 數與 gap，讓背景排程造成的長 gap 能在日誌中直接看見。
    func frameSummary(now: Double) -> String {
        frameLock.lock(); defer { frameLock.unlock() }
        func number(_ value: Double?) -> String {
            value.map { String(format: "%.6f", $0) } ?? "unknown"
        }
        let idle = lastArrival.map { max(0, now - $0) } ?? -1
        return "frames=\(frameCount) firstPTS=\(number(firstPTS)) lastPTS=\(number(lastPTS)) "
            + "maxGap=\(number(maxFrameGap)) maxGapAtPTS=\(number(maxFrameGapAtPTS)) "
            + "lastGap=\(number(lastFrameGap)) gapsOver100ms=\(frameGapsOver100ms) idle=\(number(idle))"
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
              let image = sampleBuffer.imageBuffer else { return }
        let values = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        if let status = values?[.status] as? Int, status != SCFrameStatus.complete.rawValue { return }
        let raw = (values?[.videoOrientation] as? NSNumber)?.intValue
            ?? (CMGetAttachment(sampleBuffer, key: SCStreamFrameInfo.videoOrientation.rawValue as CFString, attachmentModeOut: nil) as? NSNumber)?.intValue
        let seconds = sampleBuffer.presentationTimeStamp.seconds
        let arrival = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        var longGap: (previous: Double, current: Double, gap: Double)?
        if seconds.isFinite, seconds > 0 {
            frameLock.lock()
            frameCount += 1
            if firstPTS == nil { firstPTS = seconds }
            if let previous = lastPTS {
                let gap = seconds - previous
                lastFrameGap = gap
                if gap > maxFrameGap {
                    maxFrameGap = gap
                    maxFrameGapAtPTS = previous
                }
                if gap > 0.100 { frameGapsOver100ms += 1 }
                if gap >= 0.500 { longGap = (previous, seconds, gap) }
            }
            lastPTS = seconds
            if arrival.isFinite { lastArrival = arrival }
            frameLock.unlock()
        }
        if let longGap {
            sendlog(message: "[RecordingFrameGap] previousPTS=\(longGap.previous) currentPTS=\(longGap.current) gap=\(longGap.gap)")
        }
        timeline.observe(seconds: seconds, orientation: raw)
        if raw != lastOrientation || (raw == nil && !loggedMissing) {
            sendlog(message: "[RecordingOrientation] exif=\(raw.map(String.init) ?? "missing") pixel=\(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image)) pts=\(seconds)")
            lastOrientation = raw
            if raw == nil { loggedMissing = true }
        }
    }
}
#endif
