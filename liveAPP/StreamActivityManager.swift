import ActivityKit
import SwiftUI
import LiveActivityKit

// MARK: - ActivityManager
@MainActor
final class StreamActivityManager: ObservableObject {
    static let shared = StreamActivityManager()

    @Published private(set) var isActivityActive = false
    @Published var lastError: String? {
        didSet {
            if lastError != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.lastError = nil
                }
            }
        }
    }

    private var currentActivity: Activity<StreamActivityAttributes>? {
        didSet { isActivityActive = currentActivity != nil }
    }
    private var updateTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    func startStreamActivity(streamTitle: String = "直播中") {
        logLifecycle("== startStreamActivity 開始 ==")
        let env = ProcessInfo.processInfo.operatingSystemVersionString
        logLifecycle("環境: iOS \(env), 裝置: \(DeviceInfo.deviceCode)")

        let auth = ActivityAuthorizationInfo()
        logLifecycle("授權: areActivitiesEnabled=\(auth.areActivitiesEnabled)")
        checkActivityKitEntitlement()

        guard auth.areActivitiesEnabled else {
            lastError = "權限未開啟：請至 設定 → ReplyKit → 即時動態 開啟"
            logLifecycle("權限未開啟，中止啟動")
            return
        }

        endStreamActivity(reason: "重新啟動前清理")

        let attributes = StreamActivityAttributes(streamTitle: streamTitle)
        let initialState = StreamActivityAttributes.ContentState()
        let content = ActivityContent(state: initialState, staleDate: nil)
        logLifecycle("準備建立 Activity: title=\(streamTitle), initial=\(describeContent(initialState))")

        Task {
            await cleanupStaleActivities()
            logWidgetDiagnostics()

            do {
                let activity = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
                let count = Activity<StreamActivityAttributes>.activities.count
                logLifecycle("Activity.request 成功: id=\(activity.id), state=\(activity.activityState), 現存數=\(count)")

                guard activity.activityState != .dismissed else {
                    logLifecycle("請求回傳已清除的實例，略過")
                    return
                }
                currentActivity = activity
                startPeriodicUpdates()
                observeDismiss(for: activity)
                logLifecycle("Live Activity 已啟動")
            } catch {
                lastError = "啟動失敗: \(error.localizedDescription)"
                logLifecycle("啟動失敗: \(error)")
            }
        }
    }

    func updateStreamActivity(_ state: StreamActivityAttributes.ContentState) {
        guard let activity = currentActivity else { return }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(30))
        logLifecycle("手動 update: \(describeContent(state))")
        Task {
            await activity.update(content)
        }
    }

    func endStreamActivity(reason: String = "用戶手動結束") {
        updateTask?.cancel()
        updateTask = nil
        dismissTask?.cancel()
        dismissTask = nil

        guard let activity = currentActivity else {
            logLifecycle("endStreamActivity: currentActivity 為 nil (\(reason))")
            return
        }
        logLifecycle("endStreamActivity (\(reason)): id=\(activity.id), state=\(activity.activityState)")
        currentActivity = nil
        Task {
            let state = activity.content.state
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(5)))
            logLifecycle("Activity.end 已呼叫，5 秒後移除 id=\(activity.id)")
        }
    }

    private func cleanupStaleActivities() async {
        let all = Activity<StreamActivityAttributes>.activities
        logLifecycle("cleanupStaleActivities: 系統現存 \(all.count) 個同型別 Activity")
        let current = currentActivity
        for activity in all {
            if activity === current { continue }
            let state = activity.activityState
            logLifecycle("  id=\(activity.id) state=\(state)")
            if state == .ended || state == .dismissed {
                logLifecycle("  過期，跳過")
                continue
            }
            await activity.end(nil, dismissalPolicy: .immediate)
            logLifecycle("  已立即結束 id=\(activity.id)")
        }
    }

    private func checkActivityKitEntitlement() {
        guard let profilePath = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = FileManager.default.contents(atPath: profilePath) else {
            logLifecycle("找不到 embedded.mobileprovision（側載可能未嵌入描述檔），改用 codesign 於本機驗證")
            return
        }
        let str = String(data: data, encoding: .ascii) ?? ""
        guard let start = str.range(of: "<?xml"),
              let end = str.range(of: "</plist>", options: .backwards) else {
            logLifecycle("mobileprovision 無法解析")
            return
        }
        let plistData = Data(str[start.lowerBound...end.upperBound].utf8)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            logLifecycle("mobileprovision 缺少 Entitlements")
            return
        }
        let value = entitlements["com.apple.developer.activitykit-live-activity"]
        if value != nil {
            logLifecycle("✅ ActivityKit entitlement=\(String(describing: value))")
        } else {
            logLifecycle("❌ ActivityKit entitlement 不存在！系統會立即清除 Live Activity")
        }
    }

    private func logWidgetDiagnostics() {
        let plugInsURL = Bundle.main.bundleURL.appendingPathComponent("PlugIns")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: plugInsURL.path)) ?? []
        logLifecycle("PlugIns 內容: \(contents)")

        let widgetPath = plugInsURL.appendingPathComponent("liveAPPWidget.appex").path
        guard FileManager.default.fileExists(atPath: widgetPath),
              let widgetBundle = Bundle(path: widgetPath) else {
            logLifecycle("❌ liveAPPWidget.appex 不存在於 PlugIns")
            return
        }
        logLifecycle("✅ liveAPPWidget.appex 存在")
        if let info = widgetBundle.infoDictionary {
            let extPoint = (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] ?? "???"
            let supportsLA = info["NSSupportsLiveActivities"] ?? "???"
            logLifecycle("  NSExtensionPointIdentifier=\(extPoint)")
            logLifecycle("  NSSupportsLiveActivities=\(supportsLA)")
        }
        if let bundleID = widgetBundle.bundleIdentifier {
            logLifecycle("  BundleIdentifier=\(bundleID)")
        }
    }

    private func startPeriodicUpdates() {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            var cycle = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                cycle += 1

                guard let activity = self?.currentActivity else {
                    self?.logLifecycle("週期更新中斷: currentActivity 已為 nil (cycle=\(cycle))")
                    break
                }
                let totalSeconds = Int(LPConfig.shared.lastStreamTime)
                let hours = totalSeconds / 3600
                let minutes = (totalSeconds % 3600) / 60
                let seconds = totalSeconds % 60
                let elapsed = String(format: "%02d:%02d:%02d", hours, minutes, seconds)

                var status: StreamStatus = .live
                if LPConfig.shared.StreamEnded {
                    status = .ended
                } else if LPConfig.shared.isReconnecting {
                    status = .reconnecting(LPConfig.shared.reconnectStatus)
                }

                let updated = StreamActivityAttributes.ContentState(
                    streamStatus: status,
                    bitrate: LPConfig.shared.streamBitrate,
                    elapsedTime: elapsed,
                    viewerCount: LPConfig.shared.streamViewerCount,
                    cpuUsage: DeviceInfo.cpuUsagePercent,
                    memoryUsage: DeviceInfo.appMemoryMB
                )
                if cycle == 1 || cycle % 6 == 0 {
                    let cpu = String(format: "%.1f", DeviceInfo.cpuUsagePercent)
                    let mem = String(format: "%.1f", DeviceInfo.appMemoryMB)
                    let viewers = LPConfig.shared.streamViewerCount.map { String($0) } ?? "nil"
                    self?.logLifecycle("週期更新 #\(cycle): status=\(status) elapsed=\(elapsed) bitrate=\(LPConfig.shared.streamBitrate) viewers=\(viewers) cpu=\(cpu)% mem=\(mem)MB")
                }
                let content = ActivityContent(state: updated, staleDate: Date().addingTimeInterval(30))
                await activity.update(content)
            }
        }
    }

    private func observeDismiss(for activity: Activity<StreamActivityAttributes>) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            self?.logLifecycle("開始監聽狀態 (id=\(activity.id))")
            for await state in activity.activityStateUpdates {
                self?.logLifecycle("狀態變更 → \(state)")
                if state == .dismissed {
                    guard let self, self.currentActivity === activity else { break }
                    self.updateTask?.cancel()
                    self.updateTask = nil
                    self.currentActivity = nil
                    self.logLifecycle("已清空引用 (被清除)")
                    break
                }
            }
        }
    }

    private func logLifecycle(_ message: String) {
        sendlog(message: "[LiveActivity] \(message)")
    }

    private func describeContent(_ c: StreamActivityAttributes.ContentState) -> String {
        return "status=\(c.streamStatus) bitrate='\(c.bitrate)' elapsed=\(c.elapsedTime) viewers=\(String(describing: c.viewerCount))"
    }
}
