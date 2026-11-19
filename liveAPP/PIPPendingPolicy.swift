import Foundation

/// 等待佇列以完整訊息為淘汰單位；單則超過上限時整則略過，不留下無頭尾片段。
enum PIPPendingPolicy {
    /// 空容器允許單一超高片段前進；非空容器放不下時必須釋放舊內容。
    static func canInsert(nextBottom: Double, limit: Double, isEmpty: Bool) -> Bool {
        isEmpty || nextBottom <= limit
    }

    /// 回傳要移除的最前端片段數；parentIDs 應依訊息連續排列，limit 為片段容量。
    static func dropCount(parentIDs: [UUID], limit: Int) -> Int {
        var end = 0
        while parentIDs.count - end > max(0, limit), end < parentIDs.count {
            let parent = parentIDs[end]
            repeat { end += 1 } while end < parentIDs.count && parentIDs[end] == parent
        }
        return end
    }
}
