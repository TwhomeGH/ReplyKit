import Foundation
#if os(iOS)
import BackgroundTasks
#endif

final class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()

    private let socketKeepAliveTaskID = "com.nuclear.liveAPP.socket.keepalive"

    private init() {}

    func registerTasks() {
        #if os(iOS)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: socketKeepAliveTaskID, using: nil) { task in
            self.handleSocketKeepAliveTask(task as! BGProcessingTask)
        }
        #endif
    }

    func scheduleSocketKeepAlive() {
        #if os(iOS)
        cancelSocketKeepAlive()
        let request = BGProcessingTaskRequest(identifier: socketKeepAliveTaskID)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5)
        do {
            try BGTaskScheduler.shared.submit(request)
            sendlog(message: "已排程 BGTaskScheduler socket keepalive")
        } catch {
            sendlog(message: "BGTaskScheduler 排程失敗: \(error)")
        }
        #endif
    }

    func cancelAll() {
        #if os(iOS)
        BGTaskScheduler.shared.cancelAllTaskRequests()
        #endif
    }

    #if os(iOS)
    private func handleSocketKeepAliveTask(_ task: BGProcessingTask) {
        sendlog(message: "BGTaskScheduler socket keepalive 開始執行")

        // 排程下一次（形成循環，每次到期前再排一次）
        scheduleSocketKeepAlive()

        // 確保 SocketServer 在背景視窗中持續運作
        SocketServer.shared.start()

        var completed = false

        task.expirationHandler = {
            guard !completed else { return }
            completed = true
            sendlog(message: "BGTaskScheduler socket keepalive 到期")
            task.setTaskCompleted(success: true)
        }
    }
    #endif
}
