//import ReplayKit
//import AVFoundation
//import RTMPHaishinKit
//import HaishinKit
//
//
//class ReplayKitManager: NSObject {
//    let recorder = RPScreenRecorder.shared()
//    let rtmpStream: RTMPStream
//    let Media=MediaMixer()
//
//    init(stream: RTMPStream) {
//        self.rtmpStream = stream
//    }
//
//    func startCapture() {
//        recorder.startCapture { [weak self] sampleBuffer, sampleBufferType, error in
//            guard let self = self else { return }
//            if let error = error {
//                print("Capture failed: \(error)")
//                return
//            }
//
//            switch sampleBufferType {
//            case .video:
//                self.rtmpStream.mixer(Media, didOutput: sampleBuffer)   // 新版 HaishinKit 推送入口
//            case .audioApp, .audioMic:
//                self.rtmpStream.mixer(Media, didOutput:sampleBuffer)   // 音訊
//            @unknown default:
//                break
//            }
//
//        } completionHandler: { error in
//            if let error = error {
//                print("Start capture completion error: \(error)")
//            }
//        }
//    }
//
//    func stopCapture() {
//        recorder.stopCapture { error in
//            if let error = error {
//                print("Stop capture failed: \(error)")
//            }
//        }
//    }
//}
