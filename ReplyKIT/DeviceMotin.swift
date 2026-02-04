//
//  DeviceMotin.swift
//  liveAPP
//
//  Created by user on 2025/10/29.
//

import CoreMotion
import UIKit

@available(iOS 11.0, *)
class DeviceOrientationManager {
    static let shared = DeviceOrientationManager()

#if os(iOS)

    private var motionManager: CMMotionManager?

    // 當前偵測到的方向
    private(set) var currentOrientation: UIDeviceOrientation = .unknown

    var nowC:UIDeviceOrientation = .landscapeLeft
    // 新增 closure，方向改變時呼叫
    var orientationChanged: ((UIDeviceOrientation) -> Void)?



#elseif os(macOS)
    // macOS 沒有 UIDeviceOrientation，用 enum 模擬
    enum MacOrientation {
        case portrait, landscapeLeft, landscapeRight, portraitUpsideDown, unknown
    }
    private(set) var currentOrientation: MacOrientation = .unknown

    // 新增 closure，方向改變時呼叫
    var orientationChanged: ((MacOrientation) -> Void)?


#endif

    // 🔹 新增屬性控制是否啟用方向更新
    var isEnabled: Bool = true
    var isRotate:Bool = false

    init() { }

#if os(iOS)
    func startUpdates(interval: TimeInterval = 0.2) {
        guard motionManager == nil else { return } // 已經啟動就不用重建

        let manager = CMMotionManager()
        manager.deviceMotionUpdateInterval = interval
        motionManager = manager

        guard ((motionManager?.isDeviceMotionAvailable) != nil) else {
            return
        }

        // 改成直接使用 motion 回呼
        motionManager?.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self = self, let gravity = motion?.gravity else { return }

            let x = gravity.x
            let y = gravity.y


            let previous = self.currentOrientation


            // 取得 UIDevice 方向


            if fabs(y) >= fabs(x) {

                self.currentOrientation = y >= 0 ? .portraitUpsideDown : .portrait

            } else {
                self.currentOrientation = x >= 0 ? .landscapeRight : .landscapeLeft
            }






            if previous != self.currentOrientation {
                sendlog(message: "方向改變: \(self.currentOrientation)")
                self.orientationChanged?(self.currentOrientation)
            }

        }
    }

    func stopUpdates() {

        Task {
#if os(iOS)
            await UIDevice.current.endGeneratingDeviceOrientationNotifications()

            NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)

#endif
        }

        motionManager?.stopDeviceMotionUpdates()
        motionManager = nil
        orientationChanged = nil
    }
#endif

#if os(macOS)
    // macOS: 模擬方法，讓開發者手動設定方向
    func setOrientation(_ orientation: MacOrientation) {
        guard isEnabled else { return }
        let previous = currentOrientation
        currentOrientation = orientation
        if previous != currentOrientation {
            orientationChanged?(currentOrientation)
        }
    }
    func startUpdates(interval: TimeInterval = 0.2) {
        // macOS 沒有重力感測器，可選擇定時模擬或不做事
    }
    func stopUpdates() {
        orientationChanged = nil
    }
#endif

}
