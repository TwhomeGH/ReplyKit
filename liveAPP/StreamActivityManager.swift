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
    /// 啟動／停止世代，避免等待清理期間舊啟動請求復活。
    private var generation = UUID()
    private var streamStartedAt: Date?
    private var updateTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    func startStreamActivity(streamTitle: String = "直播中") {
        guard LiveActivitySettings.enabled, currentActivity == nil else { return }
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

        endStreamActivity(reason: "建立新活動前清理")

        let attributes = StreamActivityAttributes(streamTitle: streamTitle)
        let requestGeneration = generation
        streamStartedAt = LPConfig.shared.streamStartTime ?? Date()
        let initialState = snapshot()
        let content = ActivityContent(state: initialState, staleDate: nil)
        logLifecycle("準備建立 Activity: title=\(streamTitle), initial=\(describeContent(initialState))")

        Task {
            await cleanupStaleActivities()
            guard generation == requestGeneration, LiveActivitySettings.enabled else { return }
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
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(LiveActivitySettings.interval + 60))
        logLifecycle("手動 update: \(describeContent(state))")
        Task {
            guard currentActivity === activity else { return }
            await activity.update(content)
        }
    }

    /// 停止排程並使尚未完成的啟動請求失效；不影響推流。
    func endStreamActivity(reason: String = "活動結束（未提供原因）") {
        generation = UUID()
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
            var state = activity.content.state
            state.streamStatus = .ended
            state.endedAt = Date()
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

    /// 修改偏好後立即重排；啟用時只在直播中建立活動。
    func applySettings() {
        if !LiveActivitySettings.enabled {
            endStreamActivity(reason: "設定停用")
        } else if currentActivity != nil {
            refreshStatus()
            startPeriodicUpdates()
        } else if !LPConfig.shared.StreamEnded {
            startStreamActivity()
        }
    }

    /// 重連等狀態事件即時更新，不等待摘要週期。
    func refreshStatus() {
        updateStreamActivity(snapshot())
    }

    /// 所有更新共用同一份快照；時間基準固定，不隨每次取樣漂移。
    private func snapshot() -> StreamActivityAttributes.ContentState {
        var state = StreamActivityAttributes.ContentState(
            streamStatus: LPConfig.shared.StreamEnded ? .ended :
                (LPConfig.shared.isReconnecting ? .reconnecting(LPConfig.shared.reconnectStatus) : .live),
            bitrate: LPConfig.shared.streamBitrate,
            viewerCount: LPConfig.shared.streamViewerCount,
            cpuUsage: DeviceInfo.cpuUsagePercent,
            memoryUsage: DeviceInfo.appFootprintMB)
        state.startedAt = streamStartedAt
        state.updatedAt = Date()
        return state
    }

    /// 只排一個週期任務；取消直接退出，並核對活動身分防止舊任務更新新活動。
    private func startPeriodicUpdates() {
        updateTask?.cancel()
        guard let activity = currentActivity else { return }
        let interval = LiveActivitySettings.interval
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
                catch { return }
                guard !Task.isCancelled, let self, self.currentActivity === activity else { return }
                let state = self.snapshot()
                await activity.update(ActivityContent(state: state,
                    staleDate: Date().addingTimeInterval(interval + 60)))
                self.logLifecycle("週期更新 interval=\(interval)s：\(self.describeContent(state))")
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
