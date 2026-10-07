import ReplayKit
import SwiftUI
import Combine
import os
import Foundation

#if os(iOS)
/// 包裝系統廣播選擇器，Coordinator 沿用既有觸發入口。
struct BroadcastButton: UIViewRepresentable {
    var rtmpURL: String
    var rtmpKey: String

    func resolveExtension() -> String? {
        // 動態解析，不用 static cache
        if let plugInsURL = Bundle.main.builtInPlugInsURL,
           let entries = try? FileManager.default.contentsOfDirectory(at: plugInsURL, includingPropertiesForKeys: nil) {
            let appexEntries = entries.filter { $0.pathExtension == "appex" }
            sendlog(title: "BroadcastButton", message: "Found \(appexEntries.count) appex bundles in PlugIns")
            for entry in appexEntries {
                if let bundle = Bundle(url: entry),
                   let bundleID = bundle.bundleIdentifier,
                   let extDict = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                   let pointID = extDict["NSExtensionPointIdentifier"] as? String,
                   pointID == "com.apple.broadcast-services-upload" {
                    sendlog(title: "BroadcastButton", message: "Selected broadcast upload extension: \(bundleID)")
                    return bundleID
                }
            }
            sendlog(title: "BroadcastButton", message: "No broadcast upload extension found in PlugIns")
        } else {
            sendlog(title: "BroadcastButton", message: "No PlugIns directory or unable to read")
        }

        // fallback
        if let bundleID = Bundle.main.bundleIdentifier {
            let candidate = bundleID + ".ReplyKIT"
            sendlog(title: "BroadcastButton", message: "Fallback to constructed: \(candidate)")
            return candidate
        }

        sendlog(title: "BroadcastButton", message: "Failed to resolve broadcast extension")
        return nil
    }

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        if let ext = context.coordinator.resolveIfNeeded(resolve: { resolveExtension() }) {
            picker.preferredExtension = ext
        } else {
            sendlog(title: "BroadcastButton", message: "preferredExtension is nil, picker may not work")
        }
        picker.showsMicrophoneButton = true
        context.coordinator.attach(picker)
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        if let ext = context.coordinator.resolveIfNeeded(resolve: { resolveExtension() }), uiView.preferredExtension != ext {
            uiView.preferredExtension = ext
        }
        context.coordinator.rtmpURL = rtmpURL
        context.coordinator.rtmpKey = rtmpKey
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func triggerButton() {
        Coordinator.trigger()
    }

    class Coordinator: NSObject {
        static weak var currentPicker: RPSystemBroadcastPickerView?
        static weak var currentCoordinator: Coordinator?
        private var resolvedExtension: String?
        private var lastResolution = -Double.infinity

        /// App bundle 在程序存活期間不變；成功解析只做一次，失敗最多每五秒重試。
        func resolveIfNeeded(resolve: () -> String?) -> String? {
            if let resolvedExtension { return resolvedExtension }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastResolution >= 5 else { return nil }
            lastResolution = now
            resolvedExtension = resolve()
            return resolvedExtension
        }

        var rtmpURL: String = ""
        var rtmpKey: String = ""

        func attach(_ picker: RPSystemBroadcastPickerView) {
            Coordinator.currentPicker = picker
            Coordinator.currentCoordinator = self
            picker.layoutIfNeeded()
            for view in picker.subviews {
                if let button = view as? UIButton {
                    button.removeTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
                    button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
                }
            }
        }

        @objc func buttonTapped() {
            sendlog(title: "BroadcastButton", message: "buttonTapped 開始直播按鈕")
        }

        static func trigger(attempt: Int = 0) {
            guard let picker = currentPicker else {
                if attempt < 5 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        trigger(attempt: attempt + 1)
                    }
                } else {
                    sendlog(title: "BroadcastButton", message: "trigger() failed: currentPicker is nil after \(attempt) retries")
                }
                return
            }
            picker.layoutIfNeeded()
            guard let button = picker.subviews.first(where: { $0 is UIButton }) as? UIButton else {
                if attempt < 5 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        trigger(attempt: attempt + 1)
                    }
                } else {
                    sendlog(title: "BroadcastButton", message: "trigger() failed: no UIButton in picker subviews after \(attempt) retries")
                }
                return
            }
            sendlog(title: "BroadcastButton", message: "trigger() simulating button tap")
            DispatchQueue.main.async {
                button.sendActions(for: .touchUpInside)
            }
        }
    }
}

#endif



// MARK: 全局實時音訊模塊
