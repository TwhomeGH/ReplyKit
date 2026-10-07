import Foundation
import Network
import Darwin
import DarwinNotify
import os
import UIKit



/// 主 App 的換行分隔 JSON Socket 服務，負責 listener、連線生命週期與訊息分派。
/// 連線及收送緩衝主要由 queue 管理；@unchecked Sendable 並不代表所有狀態已隔離。
class SocketServer:ObservableObject, @unchecked Sendable {

    // MARK: - Properties

    static let shared = SocketServer()

    /// 單一連線接收緩衝上限（bytes）；超限時嘗試換行重新同步，否則關閉連線。
    static let maxBufferSize = 1_048_576
    /// 同時接受的連線數上限。
    static let maxConnections = 10

    private var receiveBuffers: [ObjectIdentifier: Data] = [:]
    /// 各連線已消耗的緩衝位置，避免逐行移除 Data 造成大量複製。
    private var receiveOffsets: [ObjectIdentifier: Int] = [:]

    private var listener: NWListener?
    /// 切換端口時的候選 listener，就緒後才取代現有服務。
    private var pendingListener: NWListener?
    @Published private(set) var listeningPort: UInt16?
    @Published private(set) var listenerStatus = "尚未啟動"
    @Published private(set) var portError: String?
    @Published private(set) var isApplyingPort = false

    /// 將 listener 摘要發布到主佇列供 UI 顯示，不用此字串判斷網路狀態。
    private func publishListenerState(_ status: String, port: UInt16? = nil) {
        DispatchQueue.main.async {
            self.listenerStatus = status
            self.listeningPort = port
        }
    }

    /// 將端口占用轉為可操作提示，其餘錯誤保留系統說明。
    private func listenerErrorMessage(_ error: Error, port: UInt16) -> String {
        if let networkError = error as? NWError,
           case .posix(.EADDRINUSE) = networkError {
            return "端口 \(port) 已被占用，請選擇其他端口。"
        }
        return "端口 \(port) 無法監聽：\(error.localizedDescription)"
    }

    /// 安裝接收與狀態回呼；忽略已被替換的 listener 回報。
    private func configureListener(_ target: NWListener, port: UInt16) {
        target.newConnectionHandler = { [weak self, weak target] connection in
            guard let self, let target, self.listener === target, self.wantsRunning else {
                connection.cancel()
                return
            }
            self.handleNewConnection(connection)
        }
        target.stateUpdateHandler = { [weak self, weak target] state in
            guard let self, let target, self.listener === target else { return }
            switch state {
            case .ready:
                self.currentRestartKey = nil
                self.publishListenerState("監聽中", port: port)
                self.logTo("SocketServer ready on port \(port)")
            case .failed(let error):
                let message = self.listenerErrorMessage(error, port: port)
                self.logTo(message)
                target.stateUpdateHandler = nil
                target.cancel()
                self.listener = nil
                self.publishListenerState(message)
                if case .posix(.EADDRINUSE) = error { self.recoveryBlocked = true; return }
                self.scheduleRestart()
            case .waiting(let error):
                self.publishListenerState("等待網路：\(error.localizedDescription)")
            case .cancelled:
                self.listener = nil
                self.publishListenerState("已停止")
                self.requestRecovery(reason: "listenerCancelled")
            default:
                break
            }
        }
    }

    /// 嘗試切換監聽端口，若 listener 尚未就緒則等待；若失敗則保留現有服務。
    /// - Parameter port: 要切換的端口號，必須在 1024–65535 範圍內。
    @MainActor
    func applyPort(_ port: UInt16) {
        guard !isApplyingPort else { return }
        guard SocketPortSettings.canCustomize else {
            portError = "此安裝模式暫不支援自訂端口。"
            return
        }
        guard port >= 1024 else {
            portError = "請輸入 1024–65535 的端口。"
            return
        }
        guard !UIScreen.main.isCaptured else {
            portError = "請先停止直播或螢幕錄製再變更端口。"
            return
        }
        isApplyingPort = true
        portError = nil
        queue.async { [self] in
            self.wantsRunning = true
            self.recoveryBlocked = false
            DispatchQueue.main.async { [weak self] in self?.isStopping = false }
            if self.listener?.state == .ready, self.listener?.port?.rawValue == port {
                DispatchQueue.main.async { self.isApplyingPort = false }
                return
            }
            do {
                let candidate = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
                self.pendingListener = candidate
                candidate.newConnectionHandler = { $0.cancel() }
                candidate.stateUpdateHandler = { [weak self, weak candidate] state in
                    guard let self, let candidate, self.pendingListener === candidate else { return }
                    switch state {
                    case .ready:
                        // 綁定是非同步操作，切換前再次確認沒有擷取工作。
                        DispatchQueue.main.async {
                            let canSwitch = !UIScreen.main.isCaptured
                            self.queue.async {
                                guard self.pendingListener === candidate else { return }
                                guard canSwitch else {
                                    self.finishPortAttempt("請先停止直播或螢幕錄製再變更端口。")
                                    return
                                }
                                self.pendingListener = nil
                                self.currentRestartKey = nil
                                self.stopInternal()
                                SocketPortSettings.save(port)
                                self.requestedPort = port
                                self.listener = candidate
                                self.configureListener(candidate, port: port)
                                self.publishListenerState("監聽中", port: port)
                                self.logTo("SocketServer switched to port \(port)")
                                DispatchQueue.main.async { self.isApplyingPort = false }
                            }
                        }
                    case .cancelled:
                        self.finishPortAttempt("端口切換已取消。")
                    case .failed(let error):
                        self.finishPortAttempt(self.listenerErrorMessage(error, port: port))
                    default:
                        break
                    }
                }
                candidate.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 5) { [weak self, weak candidate] in
                    guard let self, let candidate, self.pendingListener === candidate else { return }
                    self.finishPortAttempt("端口 \(port) 啟動逾時，請重試。")
                }
            } catch {
                self.finishPortAttempt(self.listenerErrorMessage(error, port: port))
            }
        }
    }

    /// 結束端口切換嘗試，清理候選 listener 並更新 UI 狀態。
    /// - Parameter message: 要顯示的錯誤訊息。
    private func finishPortAttempt(_ message: String) {
        pendingListener?.stateUpdateHandler = nil
        pendingListener?.cancel()
        pendingListener = nil
        requestRecovery(reason: "portAttemptEnded")
        DispatchQueue.main.async {
            self.portError = message
            self.isApplyingPort = false
        }
    }
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var lastReceiveTimes: [ObjectIdentifier: Date] = [:]
    private var keepaliveTimer: DispatchSourceTimer?

    private let queue = DispatchQueue(
                                      label: "SocketServerQueue",
                                      qos:.utility
                          )
    private let queueKey = DispatchSpecificKey<Void>()

    /// 已在服務佇列時直接執行，否則非同步排入；呼叫端不能假設返回時工作已完成。
    /// - Parameter block: 要執行的工作區塊。
    func performOnQueue(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            block()
        } else {
            queue.async(execute: block)
        }
    }

    // MARK: - 恢復狀態
    // 以下狀態僅在服務 queue 讀寫。

    /// 目前待執行的恢復識別碼；nil 表示沒有排程。
    /// 工作開始、服務就緒或資源清理時清除，使不再匹配的舊排程失效。
    private var currentRestartKey: UUID?

    /// 是否要求服務運作；明確啟動或套用端口時設為 true，停止時設為 false。
    /// 不代表 listener 已就緒，被動恢復要求不會改變此值。
    private var wantsRunning = false

    /// 是否阻擋自動恢復，例如端口被占用；明確啟動重試或套用端口時解除。
    private var recoveryBlocked = false

    /// 下次建立 listener 使用的端口；啟動時選定，成功切換端口後更新。
    private var requestedPort: UInt16 = SocketPortSettings.port

    /// 最近一次建立 listener 嘗試的系統 uptime（秒），用於計算重試冷卻時間。
    /// nil 表示尚未嘗試；不使用可能被校時改變的日曆時間。
    private var lastListenerAttempt: TimeInterval?

    /// 服務生命週期識別碼；停止或成功切換端口的資源清理時更新，
    /// 使先前等待 listener 就緒的工作失效。
    private var lifecycleGeneration = UUID()

    /// 最近一次記錄擴展恢復提示的系統 uptime（秒），僅用於日誌節流。
    /// 負無限大讓第一筆提示立即記錄，不控制實際恢復是否執行。
    private var lastRecoveryHintTime = -Double.infinity

    // MARK: - 通知註冊

    /// Darwin 通知註冊成功後取得的 token；nil 表示未成功註冊。
    /// 初始化時保存，析構時用於取消註冊。
    private var recoveryNotificationToken: Int32?

    // MARK: - UI 狀態
    // 初始化後的更新派送至主佇列。

    /// 是否明確停用服務；供 UI 觀察，不參與恢復決策。
    /// false 不代表監聽成功，實際監聽摘要應查看 listenerStatus。
    @Published private(set) var isStopping = true

    /// 將 Network 狀態轉為可測試的恢復決策輸入；未知狀態保守保留。
    private var recoveryState: SocketRecoveryPolicy.ListenerState {
        guard let listener else { return .missing }

        switch listener.state {
            case .setup: return .starting
            case .waiting: return .waiting
            case .ready: return .ready
            case .failed: return .failed
            case .cancelled: return .cancelled
            @unknown default: return .waiting
        }
    }

    /// 唯一被動恢復入口；不改變啟停意圖，不清除健康連線。
    private func requestRecovery(reason: String, minimumDelay: TimeInterval = 0) {
        dispatchPrecondition(condition: .onQueue(queue))
        let action = SocketRecoveryPolicy.action(state: recoveryState, wantsRunning: wantsRunning,
            blocked: recoveryBlocked, changingPort: pendingListener != nil,
            retryScheduled: currentRestartKey != nil)
        if reason == "extensionHint" {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastRecoveryHintTime >= 3 {
                lastRecoveryHintTime = now
                logTo("Socket recovery hint state=\(recoveryState) action=\(action)")
            }
        }
        guard action == .schedule else { return }
        let delay = SocketRecoveryPolicy.delay(now: ProcessInfo.processInfo.systemUptime,
                                               lastAttempt: lastListenerAttempt, minimum: minimumDelay)
        let key = UUID()
        currentRestartKey = key
        logTo("Socket recovery scheduled reason=\(reason) delay=\(String(format: "%.2f", delay))s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.currentRestartKey == key else { return }
            self.currentRestartKey = nil
            let action = SocketRecoveryPolicy.action(state: self.recoveryState,
                wantsRunning: self.wantsRunning, blocked: self.recoveryBlocked,
                changingPort: self.pendingListener != nil, retryScheduled: false)
            guard action == .schedule else { return }
            self.createListener()
        }
    }

    /// listener 失敗後延後恢復；重複要求合併，冷卻時間到仍會執行。
    private func scheduleRestart(delay: TimeInterval = 1.5) {
        requestRecovery(reason: "listenerFailure", minimumDelay: delay)
    }

    /// 註冊相容的 Darwin 通知名稱；通知只要求檢查服務，不是強制重啟或 App 喚醒保證。
    /// notify 的 block 指定在服務 queue 執行，以 weak self 避免懸空的 observer 指標。
    init() {
        queue.setSpecific(key: queueKey, value: ())
        var token: Int32 = 0
        let status = notify_register_dispatch("liveAPP.SocketRestart", &token, queue) { [weak self] _ in
            self?.requestRecovery(reason: "extensionHint")
        }
        if status == NOTIFY_STATUS_OK {
            recoveryNotificationToken = token
        } else {
            logTo("Socket recovery notification registration failed status=\(status)")
        }
    }

    /// 同步撤銷通知與資源，不從 deinit 排入依賴 self 的非同步清理工作。
    deinit {
        if let token = recoveryNotificationToken { notify_cancel(token) }
        keepaliveTimer?.setEventHandler {}
        keepaliveTimer?.cancel()
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        pendingListener?.stateUpdateHandler = nil
        pendingListener?.newConnectionHandler = nil
        pendingListener?.cancel()
        for connection in connections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }

    /// 用於表示閒置原因的枚舉
    /// 包含自啟動以來未有客戶端連線以及最後一個客戶端斷開連線兩種情況。
    enum IdleReason {
        /// 自啟動以來未有客戶端連線
        case noClientSinceStart
        /// 最後一個客戶端斷開連線
        case lastClientDisconnected
    }

    /// 是否允許通知聊天室訊息；若為 false，僅在 App 前景時接收訊息。
    var isNotifyApp:Bool {
        return userDefaults?.bool(forKey: "isNotifyChat") ?? false
    }

    /// 同步讀取服務佇列內的 listener 狀態；不以 UI 字串或 isStopping 判定 ready。
    var isRunning: Bool {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return listener?.state == .ready }
        return queue.sync { listener?.state == .ready }
    }

    /// 明確啟用或重試服務；重複呼叫保留 ready／setup／waiting。
    /// 變更現有監聽端口請使用 applyPort，不在 start 中破壞現有服務。
    func start(port: UInt16 = SocketPortSettings.port) {
        performOnQueue { [weak self] in
            guard let self else { return }
            guard port > 0 else { self.logTo("Socket start rejected: port=0"); return }
            self.wantsRunning = true
            self.recoveryBlocked = false
            self.requestedPort = self.listener?.port?.rawValue ?? port
            DispatchQueue.main.async { [weak self] in self?.isStopping = false }
            self.requestRecovery(reason: "explicitStart")
        }
    }

    /// 僅在統一恢復入口允許時建立 listener；不清空其他仍存活的連線。
    private func createListener() {
        dispatchPrecondition(condition: .onQueue(queue))
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        let port = requestedPort
        lastListenerAttempt = ProcessInfo.processInfo.systemUptime
        do {
            guard let endpoint = NWEndpoint.Port(rawValue: port) else { return }
            let newListener = try NWListener(using: .tcp, on: endpoint)
            listener = newListener
            configureListener(newListener, port: port)
            publishListenerState("啟動中")
            newListener.start(queue: queue)
            logTo("SocketServer starting on port \(port)")
        } catch {
            logTo("SocketServer start failed: \(error)")
            publishListenerState(listenerErrorMessage(error, port: port))
            if let error = error as? NWError, case .posix(.EADDRINUSE) = error {
                recoveryBlocked = true
                return
            }
            scheduleRestart()
        }
    }

    /// 記錄日誌訊息
    /// - Parameter
    ///  - mes : 訊息內容
    ///  - title : 訊息標題，若為 nil 則僅記錄訊息內容
    /// - Note: 此方法會將訊息內容與標題組合後記錄到日誌中，並在必要時進行格式化。
    func logTo(_ mes:String,title:String? = nil){
        if let title {
            sendlog(title:title,message: "\(mes)")
        } else {
            sendlog(message: "\(mes)")
        }

    }

    /// 被動確認服務可用；明確停止後不啟動，setup／waiting 時保留 listener。
    func ensureRunning() {
        performOnQueue { [weak self] in self?.requestRecovery(reason: "healthCheck") }
    }

    // MARK: - Handle New Connection
    /// 識別實際收到訊息的連線；遠端端點不代表已驗證的使用者或裝置身分。
    /// ObjectIdentifier 僅在物件存活期間唯一，搭配端點及建立／移除日誌追蹤。
    ///
    /// - Parameter connection: 接收訊息的實際連線。
    /// - Returns: 程序內識別碼及遠端端點，供關聯日誌使用。
    private func connectionLogContext(_ connection: NWConnection) -> String {
        return "連線=\(ObjectIdentifier(connection))｜遠端=\(connection.endpoint)"
    }

    /// 處理新的連線請求
    /// - Parameter connection: 新的網路連線
    /// - Note: 此方法會檢查當前連線數量，若超過最大限制則拒絕新連線。若接受新連線，會將其加入管理列表並啟動接收循環。
    /// 由 listener 的 newConnectionHandler 在服務佇列呼叫，不要求事先已有其他連線。
    /// - Warning: 此方法在多線程環境下可能需要額外的同步機制，以確保 connections 與 lastReceiveTimes 的正確性。
    /// 接受連線、安裝狀態回呼並啟動接收；受 maxConnections 限制。
    private func handleNewConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)

        if connections.count >= SocketServer.maxConnections {
            logTo("Max connections (\(SocketServer.maxConnections)) reached, rejecting new connection")
            connection.cancel()
            return
        }

        connections[id] = connection
        lastReceiveTimes[id] = Date()

        if connections.count == 1 {
            startKeepaliveTimer()
        }

        logTo("New connection added. \(connectionLogContext(connection))｜Total connections: \(self.connections.count)")

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }

            switch state {
            case .ready:

                if self.connections[ObjectIdentifier(connection)] != nil {
                    self.logTo("Connection ready: \(self.connectionLogContext(connection))")
                    self.replayFailedPayloads(for: connection)

                }



            case .failed(let error):
                self.logTo("Connection failed: \(error.localizedDescription)｜\(self.connectionLogContext(connection))")
                self.removeConnection(connection)

                if self.connections.isEmpty {
                    self.logTo("All connections lost, ensuring listener alive")
                    self.ensureRunning()
                }

            case .cancelled:
                self.logTo("Connection cancelled｜\(self.connectionLogContext(connection))")
                self.removeConnection(connection)
            default:
                break
            }
        }


        receiveBuffers[id] = Data()
        receiveOffsets[id] = 0

        connection.start(queue: queue)
        startReceiveLoop(for: connection)
    }



    // MARK: - Receive Data
    // 以遞迴 callback 取代 Task + withCheckedThrowingContinuation。
    // connection 以 start(queue:) 起動，receive callback 保證在 queue 上觸發，
    // 所有狀態存取因此被同一條序列 queue 序列化，無跨執行緒 race。
    // 注意：re-arm 必須經由 queue.async，避免 NWConnection 在資料已緩衝時
    // 同步觸發 completion handler 造成 unbounded recursion（見 Docs/nw-recursion.md）。
    /// 接收換行分隔 JSON，保留不完整尾段；再次接收改排佇列以避免同步遞迴。
    private func startReceiveLoop(for connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard connections[id] != nil else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard self.connections[id] != nil else { return }

            if let data = data, !data.isEmpty {
                self.lastReceiveTimes[id] = Date()
                var buffer = self.receiveBuffers[id] ?? Data()
                var offset = self.receiveOffsets[id] ?? 0

                if LPConfig.shared.SocketLog {
                    logger.debug("Socket received \(data.count) bytes")
                }

                buffer.append(data)

                if buffer.count > SocketServer.maxBufferSize {
                    if let newlineIndex = buffer[offset...].firstIndex(of: 0x0A) {
                        buffer.removeSubrange(0..<(newlineIndex + 1))
                        offset = 0
                        self.logTo("[\(id)] Buffer exceeded \(SocketServer.maxBufferSize) bytes, dropped oversized line and resynced")
                    } else {
                        self.logTo("[\(id)] Buffer exceeded \(SocketServer.maxBufferSize) bytes with no newline, closing connection")
                        self.removeConnection(connection)
                        return
                    }
                }

                while let newlineIndex = buffer[offset...].firstIndex(of: 0x0A) {
                    let lineData = buffer[offset..<newlineIndex]
                    offset = newlineIndex + 1
                    guard !lineData.isEmpty else { continue }
                    self.handleReceivedData(Data(lineData), from: connection)
                    guard self.connections[id] != nil else { return }
                }

                if offset > buffer.count / 2 {
                    buffer.removeSubrange(0..<offset)
                    offset = 0
                }

                if self.connections[id] != nil {
                    self.receiveBuffers[id] = buffer
                    self.receiveOffsets[id] = offset
                }
            }

            guard self.connections[id] != nil else { return }

            if let error = error {
                self.logTo("Receive error: \(error)")
                self.removeConnection(connection)
                return
            }

            if isComplete {
                if self.connections[id] != nil, let buffer = self.receiveBuffers[id], let offset = self.receiveOffsets[id], offset < buffer.count {
                    self.handleReceivedData(Data(buffer[offset...]), from: connection)
                }
                self.receiveBuffers[id] = nil
                self.receiveOffsets[id] = nil
                self.removeConnection(connection)
                return
            }

            self.queue.async { [weak self] in
                self?.startReceiveLoop(for: connection)
            }
        }
    }


    /// 透過 SocketServer 發送 RTMP 設定的調試訊息。
    func debugRTMP() {
        let rtmpPayload: [String: Any] = GetRTMPConfig()

        // 將字典轉換為 JSON 資料
        queueSend(dictionary: rtmpPayload)

    }

    /// 用於訊息節流的屬性，記錄上次訊息接收的時間。
    private var lastMessageTime: Date = .distantPast
    /// 訊息節流的時間間隔，單位為秒。
    private let messageThrottleInterval: TimeInterval = 0.05


    /// 透過 SocketServer 接收字典資料，並在必要時進行訊息節流。
    /// - Parameter dictionary: 要接收的字典資料。
    /// - Note: 此方法會將字典資料轉換為 JSON 格式，並在接收前檢查上次訊息接收時間，以避免過於頻繁的訊息傳輸。
    /// - Important: 請確保在呼叫此方法時，SocketServer 已經啟動並且有可用的連線，否則資料可能無法成功接收。
    /// - Warning: 此方法在多線程環境下可能需要額外的同步機制，以確保 lastMessageTime 的正確性。
    /// - Type: - Parameter dictionary: 要接收的字典資料。
    struct TypePayload: Codable {
        /// 資料類型，例如 "log"、"config"、"message" 等。
        let type:String
    }

    /// 透過 SocketServer 接收字典資料，並在必要時進行訊息節流。
    struct StreamEnded: Codable {
        /// 表示直播已結束的訊息結構，包含一個標題和訊息內容。
        let Message:String
    }

    /// 透過 SocketServer 接收字典資料，並在必要時進行訊息節流。
    struct BatchRequest: Codable {
        /// 批次請求的類型，例如 "log"、"config"、"message" 等。
        let requests: [String]
        /// 可選的資料欄位，可能包含額外的資訊，例如請求的來源、時間戳記等。
        let data: [String: String?]?

    }

    struct OverlayConfigPayload: Codable {
        let type: String
        let config: OverlaySceneConfig
    }


    // MARK: - AdOverlay and ChatMessage Structs 廣告用日誌與聊天室訊息

    /// 用於表示廣告覆蓋的結構，包含使用者、文字、圖示 URL 以及是否使用 TTS 的屬性。
    /// 此結構可用於在直播中顯示廣告訊息，並可選擇是否使用文字轉語音（TTS）功能。
    struct AdOverlay: Codable {
        /// 可選的使用者名稱，若無則為 nil。
        let user: String?
        /// 廣告文字內容。
        let text:String
        /// 可選的圖示 URL，若無則為 nil。
        let iconURL:String?
        /// 是否使用文字轉語音（TTS）功能。
        let useTTS:Bool
    }

    /// 用於表示聊天室訊息的結構，包含使用者、訊息內容以及相關屬性。
    struct ChatMessage: Codable {

        /// 是否使用文字轉語音（TTS）功能。
        let useTTS: Bool
        /// 使用者名稱，表示訊息的發送者。
        let user:String
        /// 訊息內容，表示使用者發送的文字訊息。
        let message:String
        /// 可選的使用者頭像 URL，若無則為 nil。
        let img:String?
        /// 可選的禮物圖片 URL，若無則為 nil。
        let giftImg:String?
        /// 是否為主要訊息，若無則為 nil。
        var isMain:Bool?
        /// 可選的使用者數量，若無則為 nil。此屬性可能用於表示聊天室中同一使用者的訊息數量。
        let userNum: Int?
        /// 可選的使用者列表，若無則為 nil。此屬性可能用於表示聊天室中同一使用者的訊息列表。
        let userList: [String]?

        /// 初始化聊天室訊息結構
        /// - Parameter decoder: 解碼器
        /// - Returns: 初始化後的 ChatMessage 實例
        /// - Throws: 解碼錯誤
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            useTTS = try container.decodeIfPresent(Bool.self, forKey: .useTTS) ?? true
            user = try container.decode(String.self, forKey: .user)
            message = try container.decode(String.self, forKey: .message)
            img = try container.decodeIfPresent(String.self, forKey: .img)
            giftImg = try container.decodeIfPresent(String.self, forKey: .giftImg)
            isMain = try container.decodeIfPresent(Bool.self, forKey: .isMain)
            userList = try container.decodeIfPresent([String].self, forKey: .userList)
            if let intVal = try? container.decodeIfPresent(Int.self, forKey: .userNum) {
                userNum = intVal
            } else if let strVal = try container.decodeIfPresent(String.self, forKey: .userNum) {
                userNum = Int(strVal)
            } else {
                userNum = nil
            }
        }
    }

    /// 用於表示日誌訊息的結構，包含標題與訊息內容。
    struct SLogMessage:Codable {
        /// 標題，通常用於描述日誌的來源或類型。
        let title:String
        /// 訊息內容，包含日誌的詳細資訊。
        let message:String
    }

    /// 用於表示日誌批次的結構，包含多條日誌條目以及可選的音訊音量資訊。
    struct LogBatchPayload: Codable {
        /// 多條日誌條目。
        let entries: [String]
        /// 可選的應用程式音量資訊。
        let appVol: Float?
        /// 可選的麥克風音量資訊。
        let micVol: Float?
    }

    /// 用於表示用戶偏好設定的結構，包含鍵和值類型。
    struct UPSet:Codable {
        /// 用戶偏好設定的鍵。
        let key:String
        /// 用戶偏好設定的值類型，例如 "String"、"Int"、"Bool" 等。
        let ValueType:String
    }

    /// AudioLive 用於表示音訊直播的配置，包含應用程式音量、麥克風音量以及持久化設定。
    struct AudioLive:Codable {
        /// 應用程式音量，範圍通常在 0.0 到 1.0 之間。
        var appVol:Float
        /// 麥克風音量，範圍通常在 0.0 到 1.0 之間。
        var micVol:Float
        /// 是否將音訊直播設定持久化保存。
        var persist:Bool = false
    }

    /// VideoHealthPayload 用於表示視訊健康狀態的結構，包含各種視訊處理指標。
    struct VideoHealthPayload: Codable, Sendable {

        /// 視訊健康狀態的描述，例如 "正常"、"異常" 等。
        let status: String

        // 新版（窗口彙總）：min/avg/max
        /// 輸入幀率的最小值。
        let inputFPSMin: Double?
        /// 輸入幀率的平均值。
        let inputFPSAvg: Double?
        /// 輸入幀率的最大值。
        let inputFPSMax: Double?

        /// 處理後幀率的最小值。
        let processedFPSMin: Double?
        /// 處理後幀率的平均值。
        let processedFPSAvg: Double?
        /// 處理後幀率的最大值。
        let processedFPSMax: Double?
        /// 丟失幀率的平均值。
        let droppedFPSAvg: Double?
        /// GPU 完成耗時平均值（毫秒），不是推流端到端延遲。
        let latencyAvg: Double?
        /// GPU 完成耗時最大值（毫秒）。
        let latencyMax: Double?
        /// GPU 完成耗時第 95 百分位（毫秒）。
        let latencyP95: Double?

        /// 預留 GPU 完成耗時超標的視窗內幀數；傳送端尚未量測，nil 表示未提供。
        /// 啟用時須附 latencyThresholdMs、latencySampleCount、latencyWindowSeconds。
        /// 不能以 timeoutDelta 代替，也不能據此判定網路延遲。
        let latencyExceedCount: Int?
        /// 視窗內判斷超標的毫秒閾值；目前尚未提供。
        let latencyThresholdMs: Double?
        /// 視窗內量測的幀數，供計算超標比例。
        let latencySampleCount: Int?
        /// 量測視窗長度（秒），不是整場直播累計。
        let latencyWindowSeconds: Double?


        /// 彙總視窗內 Metal 逾時次數增量，不是百分比。
        let timeoutDelta: Int

        // 舊版單值相容欄位

        /// 輸入幀率。舊版相容支持用
        /// - 注意:可能在未來版本會移除
        /// - 此屬性可能是給即時動態監控使用，應考慮其更新頻率與性能影響。
        let inputFPS: Double?

        /// 處理後幀率。舊版相容支持用
        /// - 注意:可能在未來版本會移除
        /// - 此屬性可能是給即時動態監控使用，應考慮其更新頻率與性能影響。
        let processedFPS: Double?

        /// 丟失幀率。舊版相容支持用
        /// - 注意:可能在未來版本會移除
        /// - 此屬性可能是給即時動態監控使用，應考慮其更新頻率與性能影響。
        let droppedFPS: Double?
    }

    /// AudioHealthPayload 用於表示音訊健康狀態的結構，包含各種音訊處理指標。
    struct AudioHealthPayload: Codable, Sendable {
        /// 音訊健康狀態的描述，例如 "正常"、"異常" 等。
        let status: String

        /// 保留的未分階段取樣率欄位，目前傳送端不提供。
        /// 新資料使用 StreamDiagnosticsSnapshot.mixerAudioSampleRate（混音輸出 Hz）。
        let sampleRate: Double?

        /// 視窗內每秒應用程式音訊 buffer 到達次數的最小值，不是 Hz 取樣率。
        /// 回呼頻率取決於 buffer 的 sample 數，不能用影片 60 FPS 判斷健康。
        let appInputFPSMin: Double?

        /// 應用程式輸入音訊的平均幀率。
        let appInputFPSAvg: Double?
        /// 應用程式輸入音訊的最大幀率。
        let appInputFPSMax: Double?

        /// 麥克風輸入音訊的最小幀率。
        let micInputFPSMin: Double?
        /// 麥克風輸入音訊的平均幀率。
        let micInputFPSAvg: Double?
        /// 麥克風輸入音訊的最大幀率。
        let micInputFPSMax: Double?
        /// 應用程式輸入音訊的最大間隔時間（毫秒）。
        let appGapMaxMs: Double?

        /// 對齊丟失音訊的每秒數量。
        let alignDroppedPerSec: Double?
        /// 對齊插入音訊的每秒數量。
        let alignInsertedPerSec: Double?
        /// 對齊觸發音訊的每秒數量。
        let alignFirePerSec: Double?
        /// 對齊差異的最大樣本數。
        let alignDiffMaxSamples: Double?
        /// 跳過插入音訊的每秒數量。
        let skipInsertedPerSec: Double?

        /// 音訊溢出丟失的每秒數量。
        let overflowDroppedPerSec: Double?
        /// 音訊重採樣無資料的每秒數量。
        let resampleNoDataPerSec: Double?
        /// mixer 音訊 buffer 每秒輸出次數，不是取樣率。
        let mixerOutputFPS: Double?

        /// 保留舊提案欄位，目前沒有端到端量測，nil 表示未提供。
        /// 不應將來源 PTS 與本機時間相減，或加總不同音軌耗時填入。
        let totalLatencyMs: Double?

        /// 應用程式音訊的 RMS 值。
        let appRMS: Double?
        /// 麥克風音訊的 RMS 值。
        let micRMS: Double?

        /// 輸出通道數量。
        let outChannels: Int?
        /// 輸出通道 0 的 RMS 值。
        /// 此屬性用於追蹤輸出通道 0 的 RMS 值，可能會在音訊處理過程中動態更新。
        let outCh0RMS: Double?

        /// 輸出通道 1 的 RMS 值。
        /// 此屬性用於追蹤輸出通道 1 的 RMS 值，可能會在音訊處理過程中動態更新。
        let outCh1RMS: Double?
    }

    /// AudiencePayload 用於表示觀眾資訊的結構，包含觀眾人數和觀眾名單。
    struct AudiencePayload: Codable {
        /// 觀眾人數，可能為 nil 表示未知或未提供。
        let userNum: Int?
        /// 觀眾名單，可能為 nil 表示未知或未提供。
        let userList: [String]?

        /// CodingKeys 枚舉定義了 AudiencePayload 的編碼和解碼鍵，對應 JSON 中的鍵名稱。
        enum CodingKeys: String, CodingKey {
            case userNum
            case userList
        }

        /// 從 JSON 解碼器初始化 AudiencePayload。
        /// - Parameter decoder: JSON 解碼器
        /// - Throws: 解碼錯誤
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            userList = try container.decodeIfPresent([String].self, forKey: .userList)
            if let intVal = try? container.decodeIfPresent(Int.self, forKey: .userNum) {
                userNum = intVal
            } else if let strVal = try container.decodeIfPresent(String.self, forKey: .userNum) {
                userNum = Int(strVal)
            } else {
                userNum = nil
            }
        }
    }

    /// 渲染聊天室訊息，並在需要時發送系統通知。
    /// - Parameters:
    ///  - user: 發送訊息的使用者名稱。
    ///  - msg: 聊天室訊息內容。
    ///  - img: 可選的使用者頭像 URL。
    ///  - giftImg: 可選的禮物圖片 URL。
    ///  - isMain: 指示訊息是否來自主要聊天室，預設為 true。
    ///
    func renderChatMessage(
        user: String,
        msg: String,
        img: String?,
        giftImg: String?,
        isMain:Bool = true
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastMessageTime) >= messageThrottleInterval else {
            return
        }
        lastMessageTime = now

        logTo(
            "取得聊天室訊息:\(user):\(msg) Img:\(String(describing: img)) GIFT:\(String(describing: giftImg)) isMain:\(isMain)"
        )


        if isNotifyApp {
            let (cleanBody, inlineImages, _) = PIPServiceMessages.extractAllImageURLs(from: msg, placeholder: "")
            postSystemNotification(title: user, body: cleanBody, imageURL: img, inlineImages: inlineImages)
        }

        PIPService.shared
            .addMessage(
                user:user,
                msg:msg,
                imgURL:img,
                giftURL: giftImg,
                isMain: isMain
            )





    }

    /// 更新觀眾資訊，並在有變更時標記 PIP 覆蓋層為需要重新渲染。
    /// - Parameters:
    ///  - userNum: 觀眾人數，若為 nil 則不更新。
    ///  - userList: 觀眾名單，若為 nil 則不更新。
    private func updateAudienceInfo(
        userNum: Int?,
        userList: [String]?
    ) {
        var didChange = false

        if let userNum {
            if LPConfig.shared.streamViewerCount != userNum {
                LPConfig.shared.streamViewerCount = userNum
                didChange = true
            }
        }

        if let userList,
            LPConfig.shared.streamViewerList != userList {
            LPConfig.shared.streamViewerList = userList
            didChange = true
        }

        if didChange {
            PIPService.shared.markOverlayDirty()
        }
    }


    // MARK: - 直播狀態管理 開始直播
    func StreamStarting() {

        StreamStatusChanged(isLive: true)

        LPConfig.shared.streamStartTime = Date()

        LPConfig.shared.streamViewerCount = nil
        LPConfig.shared.streamViewerList = []
        resetReconnectState()

    }

    // MARK: - 直播狀態管理 直播開始/結束 狀態更新
    func StreamStatusChanged(isLive: Bool, message: String? = nil) {
        LPConfig.shared.StreamEnded = !isLive
        LPConfig.shared.StreamEndMes = normalizedPIPStatusMessage(isLive: isLive, message: message)
        PIPService.shared.markOverlayDirty()

        if isLive {
            Task { @MainActor in
                StreamActivityManager.shared.startStreamActivity()
            }
        } else {
            Task { @MainActor in
                StreamActivityManager.shared.endStreamActivity()
            }
        }
    }

    private func normalizedPIPStatusMessage(isLive: Bool, message: String?) -> String {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return isLive ? LPConfig.shared.PIPLiveLabel : LPConfig.shared.PIPEndedLabel
        }
        if trimmed == "直播中" {
            return LPConfig.shared.PIPLiveLabel
        }
        if trimmed == "直播已結束" || trimmed == "StreamEnded" {
            return LPConfig.shared.PIPEndedLabel
        }
        return trimmed
    }

    func GetRTMPConfig() -> [String: Any]  {

        var payload: [String: Any] = [
            "type": "RTMP",
            "rtmpURL": userDefaults?.object(forKey: "rtmpURL") as? String ?? "rtmp://192.168.0.102/live",
            "rtmpKey": userDefaults?.object(forKey: "rtmpKey") as? String ?? "test",
            "BitRate": userDefaults?.object(forKey: "bitRate") as? Int ?? 3_900_000,
            "ChangeBit": userDefaults?.object(forKey: "ChangeBit") as? Bool ?? false,
            "isLowLatencyRateControlEnabled":userDefaults?.object(forKey:"isLowLatencyRateControlEnabled") as? Bool ?? false,
            "allowFrameReordering":userDefaults?.object(forKey:"allowFrameReordering") as? Bool ?? false,

            "h264useCAVLC":userDefaults?.object(forKey:"h264useCAVLC") as? Bool ?? false,

            "useEnhancedRTMP":userDefaults?.object(forKey:"useEnhancedRTMP") as? Bool ?? true,
            "isOringinAudio": (userDefaults?.object(forKey: "isOringinAudio") as? Bool) ?? true,

            "h264level": userDefaults?.object(forKey: "h264level") as? String ?? "AutoHigh",
            "videoCodec": userDefaults?
                .object(forKey: "videoCodec") as? String ?? "H264",
            "hevcLevel": userDefaults?
                .object(forKey: "hevcLevel") as? String ?? "Main",
            "BitRateMode": min(userDefaults?.object(forKey: "BitRateMode") as? Int ?? 0, 2),


            "videoBuffer": userDefaults?.object(forKey: "BufferCount") as? Int ?? -1,

            "useBic": userDefaults?.object(forKey: "useBic") as? Bool ?? false,


            "dstW": userDefaults?.object(forKey: "dstW") as? Int ?? 0,
            "dstH": userDefaults?.object(forKey: "dstH") as? Int ?? 0,

            "odstW": userDefaults?.object(forKey: "odstW") as? Int ?? 0,
            "odstH": userDefaults?.object(forKey: "odstH") as? Int ?? 0,



            "Rotate": userDefaults?.object(forKey: "Rotate") as? Int ?? 90 ,

            "RotateOriginal":userDefaults?.object(forKey: "RotateOriginal") as? Bool ?? false ,

            "enableEchoFix" : userDefaults?.object(forKey: "enableEchoFix") as? Bool ?? false,
            "enableNoiseFix": userDefaults?.object(forKey: "enableNoiseFix") as? Bool ?? false,
            "enableAGCFix" : userDefaults?.object(forKey: "enableAGCFix") as? Bool ?? false,
            "enableMetalAudio": userDefaults?.object(forKey: "enableMetalAudio") as? Bool ?? false,



            "appVolume": userDefaults?.object(forKey: "appVolume") as? Double ?? 1.0,
            "micVolume": userDefaults?
                .object(forKey: "micVolume") as? Double ?? 1.0,

            "appVolumeAdd": userDefaults?
                .object(forKey: "appAddVolume") as? Double ?? 1.0,
            "micVolumeAdd": userDefaults?
                .object(forKey: "micAddVolume") as? Double ?? 1.0,

            "KeyFrameInterval": userDefaults?.object(forKey: "KeyFrameInterval") as? Int ?? 2,
            "enableRTMPLog": userDefaults?
                .object(forKey: "enableRTMPLog") as? Bool ?? false,

        ]

        sendlog(message: "降噪設定 enableNoiseFix:\(String(describing: payload["enableNoiseFix"]))")

        if let BCount = payload["videoBuffer"] as? Int {
            if BCount < 1 && BCount != -1 {
                userDefaults?.set(-1, forKey: "BufferCount")
                payload["videoBuffer"] = -1
                sendlog(message: "修正BufferCount -> -1 (自動)")
            }
        }

        if let AppVol = payload["appVolume"] as? Double {
            if AppVol == 0.0 {
                userDefaults?.set(1.0, forKey: "appVolume")
                payload["appVolume"] = 1.0
                sendlog(message: "修正AppVol -> 1.0")
            }
        }

        if let micVol = payload["micVolume"] as? Double {
            if micVol == 0.0 {
                userDefaults?.set(1.0, forKey: "micVolume")
                payload["micVolume"] = 1.0
                sendlog(message: "修正MicVol -> 1.0")
            }
        }

        if let AppVol = payload["appVolumeAdd"] as? Double {
            if AppVol == 0.0 {
                userDefaults?.set(1.0, forKey: "appAddVolume")
                payload["appVolumeAdd"] = 1.0
                sendlog(message: "修正AppVolAdd -> 1.0")
            }
        }

        if let micVolAdd = payload["micVolumeAdd"] as? Double {
            if micVolAdd == 0.0 {
                userDefaults?.set(1.0, forKey: "micAddVolume")
                payload["micVolumeAdd"] = 1.0
                sendlog(message: "修正MicVolAdd -> 1.0")
            }
        }


        // 每次請求RTMP都重置直播狀態
        StreamStarting()

        var CPayloadKey = payload

        if let key = payload["rtmpKey"] as? String {
            CPayloadKey["rtmpKey"] = fixlogSafeKey(key)
        }


        logTo("RTMP DebugRTMP[Socket]\(CPayloadKey)")


        return payload
    }

    func GetLogConfig() -> [String: Any]  {
        let logMode = userDefaults?.object(forKey: "logMode") as? Int ?? 1
        let logURL = userDefaults?
            .object(forKey: "logURL") as? String ?? "http://192.168.0.242:3000/post"
        let onlogPage = userDefaults?.object(forKey: "onlogPage") as? Bool ?? false
        let onAudioPage = userDefaults?.object(forKey: "onAudioPage") as? Bool ?? false
        let enableLog = userDefaults?.object(forKey: "Enablelog") as? Bool ?? false
        let enableSocketLog = userDefaults?.object(forKey: "EnableSocketlog") as? Bool ?? false
        let enableTimeDebug = userDefaults?.object(forKey: "EnableTimeDebug") as? Bool ?? false
        let enablePipelineLog = userDefaults?.object(forKey: "EnablePipelineLog") as? Bool ?? false

        let enableRotatelog = userDefaults?.object(forKey: "EnableRotatelog") as? Bool ?? false


        LPConfig.shared.logMode = logMode
        LPConfig.shared.logURL = logURL
        LPConfig.shared.onLogPage = onlogPage
        LPConfig.shared.enableLog = enableLog
        LPConfig.shared.SocketLog = enableSocketLog


        let payload: [String: Any] = [
            "type": "logConfig",
            "logMode": logMode,
            "logURL": logURL,
            "onlogPage": onlogPage,
            "onAudioPage": onAudioPage,
            "enableLog": enableLog,
            "enableSocketLog": enableSocketLog,
            "enableTimeDebug": enableTimeDebug,
            "enablePipelineLog": enablePipelineLog,
            "enableRotatelog":enableRotatelog
        ]

        logTo("RTMP DebugLogConfig[Socket]\(payload)")

        return payload

    }

    func GetOverlayConfig() -> [String: Any] {
        let payload = OverlayConfigPayload(
            type: "overlayConfig",
            config: OverlayConfigStore.load()
        )
        guard let dictionary = dictionary(from: payload) else {
            logTo("OverlayConfig encode failed")
            return ["type": "overlayConfig", "config": NSNull()]
        }
        logTo("RTMP DebugOverlayConfig[Socket] enabled:\(payload.config.enabled) time:\(payload.config.time.enabled)")
        return dictionary
    }

    func pushOverlayConfig() {
        queueSend(dictionary: GetOverlayConfig())
    }

    private func dictionary<T: Encodable>(from payload: T) -> [String: Any]? {
        guard let data = try? encoder.encode(payload),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    // MARK:JSON 處理
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    /// 解析完整單行訊息的 type，再交由類型分派；不是 TCP 封包邊界。
    private func handleReceivedData(_ data: Data, from connection: NWConnection) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let base = try decoder.decode(TypePayload.self, from: data)
                self.handleDecodedPayload(data: data, type: base.type, connection: connection)
            } catch {
                self.logTo("[Socket]Decode failed ❌ \(error)")
                self.removeConnection(connection)
            }
        }
    }



    /// 分派協定訊息至設定、日誌、聊天室及診斷入口；各 UI 模型自行處理更新佇列。
    private func handleDecodedPayload(data: Data, type: String, connection: NWConnection) {
        do {


            switch type {

            case "AdOverlay":
                let dict = try decoder.decode(AdOverlay.self, from: data)

                let user = (dict.user?.isEmpty == false) ? dict.user! : "贊助訊息"

                let text = dict.text
                let iconURL = dict.iconURL
                let useTTS = dict.useTTS

                logTo("收到廣告訊息:\(user) - \(text) Icon:\(String(describing: iconURL)) TTS:\(useTTS)")


                if isNotifyApp {
                    let (cleanBody, inlineImages, _) = PIPServiceMessages.extractAllImageURLs(from: text, placeholder: "")
                    postSystemNotification(title: user, body: cleanBody, imageURL: iconURL ?? "", inlineImages: inlineImages)
                }


                Task { @MainActor in
                    if useTTS {
                        TTSService.shared.speakStreamMessage(user: user, message: text, isMain: true, force: true)
                    }
                    PIPService.shared.addAdOverlay(user: user, text: text, iconURL: iconURL, useTTS: useTTS)
                }



            case "heartbeat":
                sendlog(message: "收到 Socket 心跳｜\(connectionLogContext(connection))")

            case "StreamStarting":
                sendlog(message: "直播開始")

                StreamStarting()

            case "Ended":
                let dict = try decoder.decode(StreamEnded.self, from: data)
                let MES = dict.Message
                sendlog(message: "直播已結束: \(MES)")

                if MES != "StreamEnded" {
                    StreamStatusChanged(isLive: false, message: MES)
                } else {
                    StreamStatusChanged(isLive: false)
                }

            case "StreamMessage":
                let dict = try decoder.decode(ChatMessage.self, from: data)
                let user = dict.user
                let msg = dict.message
                let img = dict.img
                let giftImg = dict.giftImg
                let isMain = dict.isMain ?? true
                let userNum = dict.userNum
                let userList = dict.userList

                updateAudienceInfo(userNum: userNum, userList: userList)

                guard !user.isEmpty, !msg.isEmpty else {
                    logTo("訊息是空的 不需要更新子母_StreamMessage")
                    return
                }


                renderChatMessage(user: user, msg: msg, img: img, giftImg: giftImg, isMain: isMain)

                // 單則訊息只能略過朗讀；是否啟用及文字篩選仍由 TTSService 判斷。
                if dict.useTTS {
                    Task { @MainActor in
                        TTSService.shared.speakStreamMessage(user: user, message: msg, isMain: isMain)
                    }
                }

            case "UPSet":
                let dict = try decoder.decode(UPSet.self, from: data)
                let key = dict.key
                let VType = dict.ValueType

                var res: Any?
                switch VType {
                case "String":
                    res = userDefaults?.string(forKey: key)
                case "Bool":
                    res = userDefaults?.object(forKey: key) as? Bool
                case "Double":
                    res = userDefaults?.object(forKey: key) as? Double
                case "Int":
                    res = userDefaults?.object(forKey: key) as? Int
                case "Float":
                    res = userDefaults?.object(forKey: key) as? Float
                default:
                    logTo("Unknown UPSet type: \(VType)")
                    return
                }

                guard let result = res else {
                    logTo("UPSet key '\(key)' not found or type mismatch")
                    sendTo(connection, dictionary: ["type": "UPSet", "key": key, "value": NSNull()])
                    return
                }

                sendTo(connection, dictionary: ["type": "UPSet", "key": key, "value": result])

            case "batch":
                let json = try JSONSerialization.jsonObject(with: data)
                sendlog(message: "liveAppBactch Raw:\n\(json)")

                let dict = try decoder.decode(BatchRequest.self, from: data)
                let requests = dict.requests
                sendlog(message: "liveAppBactch Req:\n\(requests)")

                let batchData = dict.data
                sendlog(message: "liveAppBactch Req:\n\(String(describing: batchData))")

                var responses: [[String: Any]] = []
                for req in requests {
                    switch req {
                    case "requestRTMP":
                        responses.append(GetRTMPConfig())
                    case "logConfig":
                        responses.append(GetLogConfig())
                    case "requestOverlayConfig":
                        responses.append(GetOverlayConfig())
                    case "log":
                        if let batchData = batchData {
                            for (key, value) in batchData {
                                logTo(String(describing: value), title: String(describing: key))
                            }
                        } else {
                            logTo("data 為 nil")
                        }
                    default:
                        break
                    }
                }
                responses.append(["type": "BatchEnded"])

                for (index, resp) in responses.enumerated() {
                    sendTo(connection, dictionary: resp)
                    if index == 0, let type = resp["type"] as? String, type == "RTMP" {
                        var logResp = resp
                        if let rtmpKey = logResp["rtmpKey"] as? String {
                            logResp["rtmpKey"] = fixlogSafeKey(rtmpKey)
                        }
                        sendlog(message: "RESBatch-RTMP->\n\(logResp)")
                    } else {
                        sendlog(message: "RESBatch->\n\(resp)")
                    }
                }

            case "logConfig":
                sendTo(connection, dictionary: GetLogConfig())

            case "requestRTMP":
                sendTo(connection, dictionary: GetRTMPConfig())

            case "requestOverlayConfig":
                sendTo(connection, dictionary: GetOverlayConfig())

            case "requestSettings":
                logTo("棄用Sync UserDefaults to client 該項目不使用")

            case "audioLive":
                let dict = try decoder.decode(AudioLive.self, from: data)
                Task { @MainActor in
                    LiveVolumeModel.shared.updateVolumes(mic: dict.micVol, app: dict.appVol, persist: dict.persist)
                }
                logTo("Updated UserVol APP:\(AudioLogFormatting.linearVolume(dict.appVol)) Mic:\(AudioLogFormatting.linearVolume(dict.micVol)) Persist:\(dict.persist)")

            case "streamDiagnostics":
                let snapshot = try decoder.decode(StreamDiagnosticsSnapshot.self, from: data)
                guard snapshot.schemaVersion == 1, snapshot.source == "ReplayKit" else { return }
                Task { @MainActor in StreamDiagnosticsModel.shared.record(snapshot) }

            case "videoHealth":
                let dict = try decoder.decode(VideoHealthPayload.self, from: data)
                // 新版窗口彙總優先；舊版單值相容（min/max 用單值）
                let inputAvg = dict.inputFPSAvg ?? dict.inputFPS ?? 0
                let inputMin = dict.inputFPSMin ?? inputAvg
                let inputMax = dict.inputFPSMax ?? inputAvg
                let processedAvg = dict.processedFPSAvg ?? dict.processedFPS ?? 0
                let processedMin = dict.processedFPSMin ?? processedAvg
                let processedMax = dict.processedFPSMax ?? processedAvg
                let droppedAvg = dict.droppedFPSAvg ?? dict.droppedFPS ?? 0
                let latencyAvg = dict.latencyAvg ?? 0
                let latencyMax = dict.latencyMax ?? 0
                let latencyP95 = dict.latencyP95 ?? 0
                VideoHealthModel.shared.record(
                    status: dict.status,
                    inputFPSAvg: inputAvg, inputFPSMin: inputMin, inputFPSMax: inputMax,
                    processedFPSAvg: processedAvg, processedFPSMin: processedMin, processedFPSMax: processedMax,
                    droppedFPSAvg: droppedAvg,
                    latencyAvg: latencyAvg, latencyMax: latencyMax, latencyP95: latencyP95,
                    timeoutDelta: Double(dict.timeoutDelta), payload: dict
                )

            case "audioHealth":
                let dict = try decoder.decode(AudioHealthPayload.self, from: data)
                AudioHealthModel.shared.record(
                    status: dict.status,
                    appInputFPSMin: dict.appInputFPSMin ?? 0,
                    appInputFPSAvg: dict.appInputFPSAvg ?? 0,
                    appInputFPSMax: dict.appInputFPSMax ?? 0,
                    micInputFPSMin: dict.micInputFPSMin ?? 0,
                    micInputFPSAvg: dict.micInputFPSAvg ?? 0,
                    micInputFPSMax: dict.micInputFPSMax ?? 0,
                    appGapMaxMs: dict.appGapMaxMs ?? 0,
                    alignDroppedPerSec: dict.alignDroppedPerSec ?? 0,
                    alignInsertedPerSec: dict.alignInsertedPerSec ?? 0,
                    alignFirePerSec: dict.alignFirePerSec ?? 0,
                    alignDiffMaxSamples: dict.alignDiffMaxSamples ?? 0,
                    skipInsertedPerSec: dict.skipInsertedPerSec ?? 0,
                    overflowDroppedPerSec: dict.overflowDroppedPerSec ?? 0,
                    resampleNoDataPerSec: dict.resampleNoDataPerSec ?? 0,
                    mixerOutputFPS: dict.mixerOutputFPS ?? 0,
                    appRMS: dict.appRMS ?? 0,
                    micRMS: dict.micRMS ?? 0,
                    outChannels: dict.outChannels ?? 0,
                    outCh0RMS: dict.outCh0RMS ?? 0,
                    outCh1RMS: dict.outCh1RMS ?? 0, payload: dict
                )

            case "settings":
                let dict = try decoder.decode([String: JSONValue].self, from: data)
                if let key = dict["key"]?.propertyListValue as? String, let valueAny = dict["value"]?.propertyListValue {
                    let safeValueStr = String(describing: safeJSONValue(valueAny))
                    logTo("Updated UserDefaults: \(key) = \(safeValueStr)")
                    userDefaults?.set(valueAny, forKey: key)
                    let notificationName: String? = {
                        switch key {
                        case "appVolume": return "appVolumeChanged"
                        case "micVolume": return "micVolumeChanged"
                        case "appAddVolume": return "appAdd"
                        case "micAddVolume": return "micAdd"
                        default: return nil
                        }
                    }()
                    if let name = notificationName {
                        CFNotificationCenterPostNotification(
                            cfCenter,
                            CFNotificationName(name as CFString),
                            nil, nil, true
                        )
                    }
                }

            case "log":
                let dict = try decoder.decode(SLogMessage.self, from: data)
                receiveSocketLog(title: dict.title, message: dict.message)

            case "logbatch":
                let batch = try decoder.decode(LogBatchPayload.self, from: data)
                if let appVol = batch.appVol, let micVol = batch.micVol {
                    if appVol > 0.0 || micVol > 0.0 {
                        logTo("[Volume] recv app=\(AudioLogFormatting.linearVolume(appVol)) mic=\(AudioLogFormatting.linearVolume(micVol))")
                        Task { @MainActor in
                            LiveVolumeModel.shared.updateVolumes(mic: micVol, app: appVol)
                        }
                    }
                }
                guard LPConfig.shared.enableLog || LPConfig.shared.SocketLog else { break }
                let prefixed = batch.entries.map { "UseESocket:\($0)" }
                LogBuffer.shared.push(prefixed)
                AppLogPersister.shared.append(lines: prefixed)

            case "diagnostic":
                // 診斷訊息：只群播給其他連線（含外部工具），**不寫入 log 檔**，
                // 避免「寫入失敗→記診斷→又寫檔」的回饋迴圈；也不回送原發者。
                if let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    broadcast(dict, excluding: connection)
                }

            case "audience":
                let dict = try decoder.decode(AudiencePayload.self, from: data)
                updateAudienceInfo(userNum: dict.userNum, userList: dict.userList)

            case "reconnectStatus":
                if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = dict["status"] as? String,
                   let attempt = dict["attempt"] as? Int {
                    LPConfig.shared.reconnectAttempt = attempt
                    let maxAttempts = LPConfig.shared.reconnectMaxAttempts
                    switch status {
                    case "attempting":
                        if attempt > 0 {
                            LPConfig.shared.isReconnecting = true
                            LPConfig.shared.reconnectStatus = "🔄 \(attempt)/\(maxAttempts)"
                        } else {
                            resetReconnectState()
                        }
                    case "success":
                        resetReconnectState()
                    case "failed":
                        if attempt > 0 {
                            LPConfig.shared.isReconnecting = true
                            LPConfig.shared.reconnectStatus = "❌ \(attempt)/\(maxAttempts)"
                        } else {
                            resetReconnectState()
                        }
                    case "exhausted":
                        resetReconnectState()
                    default:
                        break
                    }
                    PIPService.shared.markOverlayDirty()
                }

            default:
                logTo("Unknown message type: \(type)")
            }

        } catch {
            self.logTo("[Socket]Decode failed ❌ \(error)")
        }
    }


    private var sendQueues: [ObjectIdentifier: [Data]] = [:]
    private var sendingFlags: [ObjectIdentifier: Bool] = [:]


    /// 將 Encodable 轉為 JSON；失敗回傳 nil，尚未加入傳輸換行。
    private func encodedData<T: Encodable>(_ payload: T) -> Data? {
        try? encoder.encode(payload)
    }


    // MARK: 群播
    /// 編碼一次後排入各連線的傳送佇列；返回不代表已送達。
    func queueSend(payload: some Encodable) {
        guard let data = encodedData(payload) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            for conn in self.connections.values {
                self.enqueue(data, to: conn)
            }
        }
    }

    /// 序列化 JSON 字典後群播；不相容的 Foundation 值使整筆略過。
    func queueSend(dictionary: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: []) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            for conn in self.connections.values {
                self.enqueue(data, to: conn)
            }
        }
    }

    /// 為指定連線排入待送資料，僅在沒有傳送工作時啟動消費。
    private func enqueue(_ data: Data, to conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        queue.async {
            var queue = self.sendQueues[id] ?? []
            queue.append(data)
            self.sendQueues[id] = queue

            if self.sendingFlags[id] != true {
                self.sendingFlags[id] = true
                self.sendNextPayload(for: conn)
            }
        }
    }

    /// 一次送出一筆並追加換行，完成回呼後續送；完成不代表對端已處理訊息。
    private func sendNextPayload(for conn: NWConnection) {
        let id = ObjectIdentifier(conn)


        queue.async { [self] in
            guard var queue = self.sendQueues[id], !queue.isEmpty else {
                self.sendingFlags[id] = false
                return
            }

            var data = queue.removeFirst()
            self.sendQueues[id] = queue

            data.append(0x0A)

            conn.send(content: data, completion: .contentProcessed { [weak self] error in

                guard let self = self else { return }

                if let error {
                    self.removeConnection(conn)
                    self.logTo("Send error: \(error)")
                    return
                }

                self.sendNextPayload(for: conn)
            })
        }
    }



    func broadcast(type:String = "settings",key: String, value: Any,to connection: NWConnection? = nil) {
        var payload: [String: Any] = [
            "type": type,
            "key": key,
            "value": safeJSONValue(value)
        ]

        if type == "log" {
            payload["message"] = value
        }

        if let conn = connection {
            logTo("使用單一廣播")
            sendTo(conn, dictionary: payload)
        } else {

            logTo("廣播給所有已連線")
            queueSend(dictionary: payload)
        }


        }


    // MARK: - 診斷群播（帶外，不寫檔）
    /// 診斷訊息專用：群播給所有連線（含外部工具），不寫入 log 檔。
    func broadcastDiagnostic(_ payload: [String: Any]) {
        queueSend(dictionary: payload)
    }

    /// 群播給除 origin 以外的所有連線（避免把診斷回送原發者）。
    private func broadcast(_ dictionary: [String: Any], excluding origin: NWConnection?) {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: []) else { return }
        let originID = origin.map { ObjectIdentifier($0) }
        queue.async { [weak self] in
            guard let self else { return }
            for (id, conn) in self.connections {
                if let originID, id == originID { continue }
                self.enqueue(data, to: conn)
            }
        }
    }

    // MARK: 一對一
    private func sendTo(_ connection: NWConnection, payload: some Encodable) {
        guard let data = encodedData(payload) else { return }
        let id = ObjectIdentifier(connection)
        queue.async {
            var queue = self.sendQueues[id] ?? []
            queue.append(data)
            self.sendQueues[id] = queue

            if self.sendingFlags[id] != true {
                self.sendingFlags[id] = true
                self.sendNextPayload(for: connection)
            }
        }
    }

    private func sendTo(_ connection: NWConnection, dictionary: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: []) else { return }
        enqueue(data, to: connection)
    }


    // MARK: - Keepalive
    private func startKeepaliveTimer() {
        stopKeepaliveTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 40)
        timer.setEventHandler { [weak self] in
            self?.sendKeepalive()
        }
        timer.activate()
        keepaliveTimer = timer
    }

    private func stopKeepaliveTimer() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    private let staleConnectionTimeout: TimeInterval = 60

    func sendKeepalive() {
        let payload: [String: Any] = ["type": "keepalive"]
        let now = Date()
        for (id, conn) in connections {
            if let lastRx = lastReceiveTimes[id], now.timeIntervalSince(lastRx) > staleConnectionTimeout {
                logTo("Connection stale (no data for \(Int(now.timeIntervalSince(lastRx)))s), removing")
                removeConnection(conn)
                continue
            }
            sendTo(conn, dictionary: payload)
        }
    }

    func broadcastPushState(key: String, value: Bool) {
        let payload: [String: Any] = ["type": "pushState", "key": key, "value": value]
        performOnQueue { [weak self] in
            guard let self else { return }
            for (_, conn) in self.connections {
                self.sendTo(conn, dictionary: payload)
            }
        }
    }

    // MARK: - Connection Cleanup
    private var pendingFailedPayloads: [ObjectIdentifier: [Data]] = [:]

    private func removeConnection(_ connection: NWConnection) {
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            queue.async { [weak self] in
                self?.removeConnection(connection)
            }
            return
        }

        let id = ObjectIdentifier(connection)

        guard connections[id] != nil else { return }

        connection.stateUpdateHandler = nil
        connection.cancel()

        if let pendingQueue = sendQueues[id], !pendingQueue.isEmpty {
            pendingFailedPayloads[id] = pendingQueue
            self.logTo("Saved \(pendingQueue.count) pending payloads for re-queue")
        }

        connections[id] = nil
        receiveBuffers[id] = nil
        receiveOffsets[id] = nil
        lastReceiveTimes[id] = nil
        sendQueues[id] = nil
        sendingFlags[id] = nil
        if connections.isEmpty {
            stopKeepaliveTimer()
        }

        logTo("Connection removed. \(connectionLogContext(connection))｜Remaining: \(self.connections.count)")
    }

    private func replayFailedPayloads(for connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard let failedPayloads = pendingFailedPayloads.removeValue(forKey: id),
              !failedPayloads.isEmpty else { return }
        self.logTo("Re-playing \(failedPayloads.count) saved payloads")
        for payload in failedPayloads {
            enqueue(payload, to: connection)
        }
    }

    /// 明確停止並使所有排程恢復失效；後續通知不能重新啟動服務。
    func stop() {
        performOnQueue { [weak self] in
            guard let self else { return }
            self.wantsRunning = false
            DispatchQueue.main.async { [weak self] in self?.isStopping = true }
            self.stopInternal()
        }
    }


    // MARK: - Suspend / Resume
    /// 關閉現有客戶端與保活 timer，保留 listener 及允許恢復的意圖；不是 stop。
    func suspend() {
        logTo("SocketServer 暫停（釋放連線但保留 listener）")
        queue.async { [weak self] in
            guard let self = self else { return }
            for (_, conn) in self.connections {
                conn.stateUpdateHandler = nil
                conn.cancel()
            }
            self.stopKeepaliveTimer()
            self.connections.removeAll()
            self.receiveBuffers.removeAll()
            self.receiveOffsets.removeAll()
            self.lastReceiveTimes.removeAll()
            self.sendQueues.removeAll()
            self.sendingFlags.removeAll()
            self.pendingFailedPayloads.removeAll()
        }
    }

    /// 明確恢復服務；已有 listener 時保留它，與 start 共用恢復判斷。
    func resume() { start() }

    /// 開始直播前清理失效連線；保留 ready／preparing 的連線。
    func prepareForBroadcast() {
        logTo("SocketServer 準備直播：清理失效連線，保留健康連線")
        performOnQueue { [weak self] in
            guard let self else { return }
            self.clearStaleBroadcastConnections()
        }
    }

    /// 開始直播前同步到 listener ready，避免 Broadcast Extension 首次請求撞上 server 尚未啟動。
    func prepareForBroadcastAndWaitReady(timeout: TimeInterval = 3.0) async -> Bool {
        await withCheckedContinuation { continuation in
            logTo("SocketServer 準備直播並等待 listener ready")
            performOnQueue { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }

                // 只清理非 ready 的殘留連線，保留仍健康的連線，
                // 避免取消 extension 正在使用的連線導致連不上擴展。
                guard self.pendingListener == nil else {
                    self.logTo("Socket port change in progress, retry broadcast after completion")
                    continuation.resume(returning: false)
                    return
                }
                self.clearStaleBroadcastConnections()
                self.start()

                let deadline = DispatchTime.now() + timeout
                self.waitForReady(deadline: deadline, generation: self.lifecycleGeneration, continuation: continuation)
            }
        }
    }

    /// 開始直播前清理殘留/失效的連線；保留健康連線（ready 已就緒、preparing 握手進行中）。
    /// 連線會因 extension 進程終止而 RST，或由 keepalive（60s 無資料）清理，
    /// 這裡只需清除尚未被 stateUpdateHandler 移除的殘留連線。
    private func clearStaleBroadcastConnections() {
        dispatchPrecondition(condition: .onQueue(queue))

        let staleIDs = connections.compactMap { id, conn -> ObjectIdentifier? in
            switch conn.state {
            case .ready, .preparing:
                return nil
            default:
                return id
            }
        }

        guard !staleIDs.isEmpty else { return }

        for id in staleIDs {
            guard let conn = connections[id] else { continue }
            conn.stateUpdateHandler = nil
            conn.cancel()
            connections[id] = nil
            receiveBuffers[id] = nil
            receiveOffsets[id] = nil
            lastReceiveTimes[id] = nil
            sendQueues[id] = nil
            sendingFlags[id] = nil
            pendingFailedPayloads[id] = nil
        }

        if connections.isEmpty {
            stopKeepaliveTimer()
        }

        logTo("Cleared \(staleIDs.count) stale broadcast connections")
    }

    /// 在服務佇列輪詢 ready；停止／切換端口使舊世代失效，或於期限到達時回傳 false。
    private func waitForReady(
        deadline: DispatchTime,
        generation: UUID,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        dispatchPrecondition(condition: .onQueue(queue))

        guard wantsRunning, lifecycleGeneration == generation else { continuation.resume(returning: false); return }
        if listener?.state == .ready {
            logTo("SocketServer listener ready for broadcast")
            continuation.resume(returning: true)
            return
        }

        if DispatchTime.now().uptimeNanoseconds >= deadline.uptimeNanoseconds {
            logTo("SocketServer listener ready timeout (state: \(listener?.state.stateString ?? "nil"))")
            continuation.resume(returning: false)
            return
        }

        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else {
                continuation.resume(returning: false)
                return
            }
            self.waitForReady(deadline: deadline, generation: generation, continuation: continuation)
        }
    }

    /// 服務 queue 上完整釋放資源；不改變啟停意圖，端口切換也會使用。
    private func stopInternal() {
        dispatchPrecondition(condition: .onQueue(queue))
        currentRestartKey = nil
        lifecycleGeneration = UUID()
        if pendingListener != nil {
            finishPortAttempt("服務已停止，請重新套用端口。")
        }
        publishListenerState("已停止")
        for (_, conn) in connections {
            conn.stateUpdateHandler = nil
            conn.cancel()
        }

        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()

        listener = nil

        stopKeepaliveTimer()
        connections.removeAll()
        receiveBuffers.removeAll()
        receiveOffsets.removeAll()
        lastReceiveTimes.removeAll()
        sendQueues.removeAll()
        sendingFlags.removeAll()
        pendingFailedPayloads.removeAll()

        logTo("SocketServer stopped")
    }



    // MARK: - Utils
    /// 遞迴轉換 Date／URL／Data 供傳送或日誌使用；不是任意型別的完整 JSON 驗證器。
    private func safeJSONValue(_ value: Any) -> Any {
        switch value {
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let url as URL:
            return url.absoluteString
        case let data as Data:
            return data.base64EncodedString()
        case let dict as [String: Any]:
            return dict.mapValues { safeJSONValue($0) }
        case let array as [Any]:
            return array.map { safeJSONValue($0) }
        default:
            return value
        }
    }

    /// 清除主 App 顯示的重連狀態，不直接建立網路連線。
    private func resetReconnectState() {
        LPConfig.shared.isReconnecting = false
        LPConfig.shared.reconnectAttempt = 0
        LPConfig.shared.reconnectStatus = ""
    }

}


// MARK:日誌內容保護StreamKey不全顯示
func fixlogSafeKey(_ str:String) -> String{
    var g = str
    let replaceCount = min(5, g.count)
    let endIndex = g.index(g.endIndex, offsetBy: -replaceCount)
    let prefix = String(g[..<endIndex])

    if replaceCount > 2 {
        let startOfReplace = g.index(g.endIndex, offsetBy: -replaceCount)
        let midEnd = g.index(g.endIndex, offsetBy: -2)
        let middle = g[startOfReplace..<midEnd]
        g = prefix + middle + "00"
    } else {
        g = String(repeating: "0", count: g.count)
    }

    return g
}
