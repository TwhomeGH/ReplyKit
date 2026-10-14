import Foundation

/// 一場錄影的顯示模型；合併產物不重複計入來源時長與容量。
struct RecordingGroup: Identifiable {
    let id: UUID
    let items: [LocalRecording]
    var segments: [LocalRecording] { items.filter { $0.segmentGroup == id } }
    var isSegmented: Bool { !segments.isEmpty }
    var segmentCount: Int { segments.count }
    var created: Date { items.map(\.created).min() ?? .distantPast }
    var duration: Double { segments.reduce(0) { $0 + $1.duration } }
    var bytes: Int64 { segments.reduce(0) { $0 + $1.bytes } }
    /// 單段完成與缺段分開提示，避免把不需合併誤認為錄影失敗。
    var statusText: String {
        if canMerge { return "片段已完成，可展開播放或合併" }
        if segments.count == 1, segments.first?.phase == .ready, segments.first?.segmentNumber == 1 {
            return "單段錄影已完成，無需合併"
        }
        return "包含尚未完成或缺失片段，請展開檢查"
    }
    /// 至少兩個完成片段，且序號從 1 連續，才可合併。
    var canMerge: Bool {
        segments.count >= 2 && segments.allSatisfy { $0.phase == .ready } &&
        segments.compactMap(\.segmentNumber).sorted() == Array(1...segments.count)
    }

    /// 將來源片段與其合併產物歸入同組，其餘檔案獨立顯示。
    /// - Parameter recordings: 錄製庫目前的完整紀錄。
    /// - Returns: 依場次開始時間由新到舊排列的群組。
    static func make(_ recordings: [LocalRecording]) -> [RecordingGroup] {
        Dictionary(grouping: recordings, by: { $0.segmentGroup ?? $0.mergedFromGroup ?? $0.id })
            .map { key, values in
                RecordingGroup(id: key, items: values.sorted {
                    ($0.segmentNumber ?? Int.max) < ($1.segmentNumber ?? Int.max)
                })
            }
            .sorted { $0.created > $1.created }
    }
}
