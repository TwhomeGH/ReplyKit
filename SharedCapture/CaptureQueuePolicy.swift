import Foundation

/// 擷取端樣本佇列的延遲與容量政策。
///
/// `maxDelay` 只限制樣本在佇列中的最長等待時間，不是編碼器延遲，也不是 GPU 處理時間。
/// 推流為了避免舊畫面累積而保留較短的樣本停留上限；錄製則以完整性優先，不再用 100ms
/// 把影片或音訊當成過期資料丟掉。
struct CaptureQueuePolicy: Sendable, Equatable {
    let videoBudget: Int
    let videoMaxDelay: TimeInterval
    let audioBudget: Int
    let audioMaxDelay: TimeInterval

    /// 依工作模式選擇影片與音訊政策。
    /// - Parameters:
    ///   - streaming: 是否要推流；推流需要較低的畫面延遲。
    ///   - recording: 是否要本地錄製；錄製需要較大的容量與較寬鬆的樣本停留上限。
    static func make(streaming: Bool, recording: Bool) -> CaptureQueuePolicy {
        if recording {
            // 錄製優先完整；只有推流並錄製時才把延遲壓在 1 秒內。
            return CaptureQueuePolicy(
                videoBudget: streaming ? 24 * 1024 * 1024 : 32 * 1024 * 1024,
                videoMaxDelay: streaming ? 1.0 : 5.0,
                audioBudget: 2 * 1024 * 1024,
                audioMaxDelay: .infinity)
        }
        return CaptureQueuePolicy(
            videoBudget: 12 * 1024 * 1024,
            videoMaxDelay: 0.5,
            audioBudget: 2 * 1024 * 1024,
            audioMaxDelay: .infinity)
    }

    /// 供診斷確認本次 session 實際套用的政策。
    var summary: String {
        let videoText = videoMaxDelay.isFinite ? String(format: "%.1fs", videoMaxDelay) : "none"
        let audioText = audioMaxDelay.isFinite ? String(format: "%.1fs", audioMaxDelay) : "none"
        return "videoBudget=\(videoBudget) videoMaxDelay=\(videoText) "
            + "audioBudget=\(audioBudget) audioMaxDelay=\(audioText)"
    }
}
