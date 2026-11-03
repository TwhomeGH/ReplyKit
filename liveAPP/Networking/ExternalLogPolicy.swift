import Foundation

/// 外部日誌的訂閱角色與容量規則；不接觸連線或佇列，可獨立驗證。
enum ExternalLogPolicy {
    /// 擴展專用訊息；收到即視為擴展連線並撤銷外部日誌訂閱。
    /// 單筆 `log` 與批次 `logbatch` 都只由擴展送出。
    static let extensionMessageTypes: Set<String> = [
        "log", "logbatch", "videoHealth", "audioHealth", "reconnectStatus"
    ]

    /// 單批上限；超過整批略過。
    static let maxBatchBytes = 256 * 1024
    /// 單一接收者待送佇列上限。
    static let maxPendingBatches = 32
    static let maxPendingBytes = 512 * 1024

    static func marksExtension(_ messageType: String) -> Bool {
        extensionMessageTypes.contains(messageType)
    }

    static func acceptsBatch(bytes: Int) -> Bool {
        bytes > 0 && bytes <= maxBatchBytes
    }

    static func canEnqueue(pendingBatches: Int, pendingBytes: Int, newBatchBytes: Int) -> Bool {
        pendingBatches < maxPendingBatches
            && pendingBytes + newBatchBytes <= maxPendingBytes
    }

    /// 取出最多 `limit` 筆與目前通道相符的項目；不符者視為切換前的殘留直接丟棄，
    /// 避免 HTTP 舊資料被送往 Socket 工具，或反向 POST 到 Web。
    static func takeDrainable<Item>(_ entries: inout [ExternalLogEntry<Item>],
                                    transport: String, limit: Int) -> [Item] {
        entries.removeAll { $0.transport != transport }
        let count = min(limit, entries.count)
        let result = entries.prefix(count).map(\.item)
        entries.removeFirst(count)
        return result
    }
}

/// 緩衝項目連同產生時的通道；切換通道後不再跨通道重播。
struct ExternalLogEntry<Item> {
    let transport: String
    let item: Item
}

/// 外部日誌訂閱集合；ID 由呼叫端提供（正式路徑為 ObjectIdentifier）。
struct ExternalLogSubscriptions<ID: Hashable> {
    private(set) var externalIDs: Set<ID> = []
    private(set) var extensionIDs: Set<ID> = []

    var count: Int { externalIDs.count }

    /// 擴展角色優先：一旦被標記，即永久排除於外部日誌之外。
    mutating func markExtension(_ id: ID) {
        extensionIDs.insert(id)
        externalIDs.remove(id)
    }

    /// 回傳訂閱是否成立；擴展連線不得訂閱。
    @discardableResult
    mutating func setSubscribed(_ subscribed: Bool, id: ID) -> Bool {
        if subscribed, !extensionIDs.contains(id) {
            externalIDs.insert(id)
        } else {
            externalIDs.remove(id)
        }
        return externalIDs.contains(id)
    }

    /// 剔除已不存在的連線；重連必須重新識別角色並重新訂閱。
    mutating func retainExisting(_ isPresent: (ID) -> Bool) {
        externalIDs = externalIDs.filter(isPresent)
        extensionIDs = extensionIDs.filter(isPresent)
    }

    func receivesExternalLogs(_ id: ID) -> Bool {
        externalIDs.contains(id) && !extensionIDs.contains(id)
    }
}
