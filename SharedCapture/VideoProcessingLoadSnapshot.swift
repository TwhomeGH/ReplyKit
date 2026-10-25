import Foundation

/// 單一影片加工 worker 的區間忙碌時間；包含同步等待，不是 CPU／GPU 使用率。
struct VideoProcessingLoadSnapshot: Codable, Sendable {
    /// 實際取樣間隔秒數；週期目標五秒，排程延遲時使用真實間隔。
    let intervalSeconds: Double
    /// 區間內加工忙碌秒數，包含跨邊界的在途加工。
    let busySeconds: Double
    /// 取樣時是否仍有一幀正在加工。
    let inFlight: Bool
    /// 0 到 100 的 worker 忙碌百分比。
    var busyPercent: Double { min(100, max(0, busySeconds / intervalSeconds * 100)) }
}
