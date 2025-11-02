#if os(macOS)
import SwiftUI
import AppKit
import AVFoundation

struct BroadcastButtonMac: View {
    @ObservedObject var coordinator: Coordinator

    var body: some View {
        Button(action: startBroadcast) {
            Text("開始直播Mac")
                .frame(width: 140, height: 40)
                .padding()
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(8)
        }
    }

    func startBroadcast() {
        let broadcaster = MacScreenBroadcaster(rtmpURL: coordinator.rtmpURL, rtmpKey: coordinator.rtmpKey)
        broadcaster.startBroadcast()
    }

    class Coordinator: ObservableObject {
        @Published var rtmpURL: String
        @Published var rtmpKey: String

        init(rtmpURL: String = "", rtmpKey: String = "") {
            self.rtmpURL = rtmpURL
            self.rtmpKey = rtmpKey
        }
    }
}

// MARK: - macOS 原生廣播替代
class MacScreenBroadcaster: NSObject {
    private let captureSession = AVCaptureSession()
    private var rtmpURL: String
    private var rtmpKey: String

    init(rtmpURL: String, rtmpKey: String) {
        self.rtmpURL = rtmpURL
        self.rtmpKey = rtmpKey
        super.init()
    }

    func startBroadcast() {
        // 設定螢幕捕獲
        guard let input = AVCaptureScreenInput(displayID: CGMainDisplayID()) else {
            print("無法取得螢幕輸入")
            return
        }
        captureSession.addInput(input)

        // 設定音訊捕獲
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice) {
            captureSession.addInput(audioInput)
        }

        // 設定輸出
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        captureSession.addOutput(videoOutput)

        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "audioQueue"))
        captureSession.addOutput(audioOutput)

        captureSession.startRunning()
        print("macOS 廣播啟動: \(rtmpURL)/\(rtmpKey)")
    }
}

extension MacScreenBroadcaster: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // 這裡把 sampleBuffer 餵給 RTMP 推流框架，例如 HaishinKit
    }
}
#endif
