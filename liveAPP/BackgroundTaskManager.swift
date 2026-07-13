import Foundation
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

final class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()

    private let socketKeepAliveTaskID = "com.nuclear.liveAPP.socket.keepalive"
    #if os(iOS)
    private var socketBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    private init() {}

    private final class CompletionState: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func markCompleted() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return false }
            completed = true
            return true
        }
    }

    func registerTasks() {
        #if os(iOS)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: socketKeepAliveTaskID, using: nil) { task in
            self.handleSocketRefreshTask(task)
        }
        #endif
    }

    func scheduleSocketRefresh() {
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: socketKeepAliveTaskID)
        let request = BGProcessingTaskRequest(identifier: socketKeepAliveTaskID)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            sendlog(message: "已排程 BGTaskScheduler socket refresh")
        } catch {
            sendlog(message: "BGTaskScheduler 排程失敗: \(error)")
        }
        #endif
    }

    func beginSocketBackgroundWindow() {
        #if os(iOS)
        guard !PIPService.shared.isPiPActive else {
            sendlog(message: "PiP 活躍中，跳過 bgTask")
            return
        }
        endSocketBackgroundWindow()
        socketBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SocketServerGraceWindow") { [weak self] in
            sendlog(message: "Socket background window 到期")
            self?.endSocketBackgroundWindow()
        }
        sendlog(message: "Socket background window 已啟動 id:\(socketBackgroundTaskID.rawValue)")
        #endif
    }

    func endSocketBackgroundWindow() {
        #if os(iOS)
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.endSocketBackgroundWindow()
            }
            return
        }
        guard socketBackgroundTaskID != .invalid else { return }
        let taskID = socketBackgroundTaskID
        socketBackgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(taskID)
        sendlog(message: "Socket background window 已結束 id:\(taskID.rawValue)")
        #endif
    }

    func cancelAll() {
        #if os(iOS)
        BGTaskScheduler.shared.cancelAllTaskRequests()
        endSocketBackgroundWindow()
        #endif
    }

    #if os(iOS)
    private func handleSocketRefreshTask(_ task: BGTask) {
        sendlog(message: "BGTaskScheduler socket refresh 開始執行")

        // BGTaskScheduler 是機會型喚醒，不保證準時或長時間保活。
        scheduleSocketRefresh()

        // 只做短工作：確保 listener 可建立，然後立即完成任務。
        SocketServer.shared.start()

        let completionState = CompletionState()

        task.expirationHandler = {
            guard completionState.markCompleted() else { return }
            sendlog(message: "BGTaskScheduler socket refresh 到期")
            task.setTaskCompleted(success: false)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard completionState.markCompleted() else { return }
            task.setTaskCompleted(success: true)
            sendlog(message: "BGTaskScheduler socket refresh 完成")
        }
    }
    #endif
}
