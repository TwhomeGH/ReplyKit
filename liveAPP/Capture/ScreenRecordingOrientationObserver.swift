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
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
              let image = sampleBuffer.imageBuffer else { return }
        let values = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        if let status = values?[.status] as? Int, status != SCFrameStatus.complete.rawValue { return }
        let raw = (values?[.videoOrientation] as? NSNumber)?.intValue
            ?? (CMGetAttachment(sampleBuffer, key: SCStreamFrameInfo.videoOrientation.rawValue as CFString, attachmentModeOut: nil) as? NSNumber)?.intValue
        let seconds = sampleBuffer.presentationTimeStamp.seconds
        timeline.observe(seconds: seconds, orientation: raw)
        if raw != lastOrientation || (raw == nil && !loggedMissing) {
            sendlog(message: "[RecordingOrientation] exif=\(raw.map(String.init) ?? "missing") pixel=\(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image)) pts=\(seconds)")
            lastOrientation = raw
            if raw == nil { loggedMissing = true }
        }
    }
}
#endif
