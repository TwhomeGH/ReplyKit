

#if os(iOS)
import UIKit
import CoreMotion


final class StableLockRotationDetector {

    static let shared = StableLockRotationDetector()
    private let motionManager = CMMotionManager()

    var onLockStateDetected: ((Bool) -> Void)?
    var debugMode: Bool = false
    private func log(_ message: String) {
        if debugMode { print(message) }
    }

    private var physicalHistory: [UIInterfaceOrientation] = []
    private let historySize = 5
    private var lastReportedState: Bool?
    private var stableCounter = 0
    private let stableThreshold = 3

    private let tiltTolerance: Double = 0.15
    private let flatZThreshold: Double = 0.85 // 平放判定
    private let nearFlatZThreshold: Double = 0.5 // 微傾斜容錯


    private init() {}

    func startMonitoring(interval: TimeInterval = 0.1) {
        motionManager.deviceMotionUpdateInterval = interval
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self = self, let motion = motion else { return }
            self.checkLock(with: motion)
        }
    }

    func stopMonitoring() {
        motionManager.stopDeviceMotionUpdates()
        physicalHistory.removeAll()
        lastReportedState = nil
        stableCounter = 0
    }


    private func checkLock(with motion: CMDeviceMotion) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first else { return }

        let currentUIOrientation = scene.interfaceOrientation
        let g = motion.gravity
        let gz =  abs(g.z)
        // 平放判定
        let isFlat = gz > flatZThreshold
        if isFlat {
            // 平放時維持上次鎖定狀態，不更新緩衝區
            log("📌 平放，維持鎖定狀態: \(lastReportedState ?? false)")
            return
        }
        if gz > nearFlatZThreshold && gz <= flatZThreshold {
            // 微傾斜 → 認為接近平放，暫不切換非鎖定
            log("🔹 微傾斜，暫不切換鎖定 \(gz)")
            return
        }

        // 推算期望方向
        let threshold: Double = 0.5
        var expectedOrientation: UIInterfaceOrientation?

        if abs(g.x) > abs(g.y) && abs(g.x) > threshold {
            expectedOrientation = g.x > 0 ? .landscapeLeft : .landscapeRight
        } else if abs(g.y) > threshold {
            expectedOrientation = g.y > 0 ? .portraitUpsideDown : .portrait
        }

        guard let expected = expectedOrientation else { return }

        log("Gravity → x:\(String(format: "%.2f", g.x)) y:\(String(format: "%.2f", g.y)) z:\(String(format: "%.2f", g.z))")
        log("期望方向: \(expected.rawValue), UI: \(currentUIOrientation.rawValue)")

        // 更新緩衝區
        physicalHistory.append(expected)
        if physicalHistory.count > historySize {
            physicalHistory.removeFirst()
        }

        let uiCategory = category(from: currentUIOrientation)

        // 微晃容錯判斷
        let isTilted: Bool
        switch expected {
        case .portrait, .portraitUpsideDown:
            isTilted = abs(g.y) < threshold - tiltTolerance
        case .landscapeLeft, .landscapeRight:
            isTilted = abs(g.x) < threshold - tiltTolerance
        default:
            isTilted = false
        }

        // 判斷鎖定
        let hasMismatch = physicalHistory.contains { category(from: $0) != uiCategory }
        let currentLocked = (expected != currentUIOrientation) || hasMismatch || isTilted

        // 防抖動
        if lastReportedState == nil || currentLocked != lastReportedState {
            stableCounter += 1
            if stableCounter >= stableThreshold {
                lastReportedState = currentLocked
                stableCounter = 0
                log("⚡ UI:\(currentUIOrientation.rawValue) 期望:\(expected.rawValue) → 鎖定:\(currentLocked)")
                onLockStateDetected?(currentLocked)
            }
        } else {
            stableCounter = 0
        }
    }

    private func category(from orientation: UIInterfaceOrientation) -> String {
        switch orientation {
        case .portrait, .portraitUpsideDown: return "portrait"
        case .landscapeLeft, .landscapeRight: return "landscape"
        default: return "unknown"
        }
    }
}
//
//  LockDetect.swift
//  liveAPP
//
//  Created by user on 2025/9/13.
//


#endif
