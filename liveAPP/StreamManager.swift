
#if os(iOS)
import UIKit

class OrientationObserver {
    static let shared = OrientationObserver()
    
    private init() {
        // 註冊 scene 變化通知（可選）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDidChange),
            name: UIScene.didActivateNotification,
            object: nil
        )
    }

    var currentOrientation: UIInterfaceOrientation {
        // 取得 key window scene
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        return windowScene?.interfaceOrientation ?? .unknown
    }

    @objc private func sceneDidChange() {
        let orientation = currentOrientation
        // 存到 App Group
        let userDefaults = UserDefaults(suiteName: "group.nuclear.liveAPP")
        userDefaults?.set(orientation.rawValue, forKey: "LOrientation")
    }
}


#endif
