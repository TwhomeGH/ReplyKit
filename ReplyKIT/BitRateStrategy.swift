import HaishinKit
import Foundation

// MARK: 碼率統計策略（組合：內建適應 + 統計，不取代）
// 保留 StreamVideoAdaptiveBitRateStrategy 的壅塞適應
// （publishInsufficientBWOccured 降速 / status 回復爬升 / reset 復原），
// 此策略只額外收集 NetworkMonitor 統計並輸出節流日誌，不直接碰 bitrate。
final actor MyStreamBitRateStrategy: @preconcurrency StreamBitRateStrategy {
    private let inner: StreamVideoAdaptiveBitRateStrategy

    var mamimumVideoBitRate: Int {
        Task { await inner.mamimumVideoBitRate }.value
    }
    var mamimumAudioBitRate: Int {
        Task { await inner.mamimumAudioBitRate }.value
    }

    // 指數移動平均（bit/s），tau 控制平滑時間常數
    private var avgOutBps: Double?
    private var lastAvgUpdateTime: Date?
    private let tau: TimeInterval = 3.0

    // 統計日誌節流：每 N 次 status 事件才寫一次 log
    private var statsLogCounter: Int = 0
    private let statsLogInterval: Int = 10

    init(videoBitRate: Int = 6_000_000,
         audioBitRate: Int = 128_000) {
        self.inner = StreamVideoAdaptiveBitRateStrategy(mamimumVideoBitrate: videoBitRate)
    }

    func adjustBitrate(_ event: HaishinKit.NetworkMonitorEvent, stream: some HaishinKit.StreamConvertible) async {
        // 內建壅塞適應：壅塞時降 bitrate，健康時回復爬升，reset 復原
        await inner.adjustBitrate(event, stream: stream)

        // 以下只讀統計，不動 bitrate
        guard case .status(let report) = event else { return }
        let currentOut = report.currentBytesOutPerSecond
        updateAvgOutBps(latest: Double(currentOut * 8))

        statsLogCounter += 1
        guard statsLogCounter >= statsLogInterval else { return }
        statsLogCounter = 0
        sendlog(
            message: "BitRate統計: AVG: \((avgOutBps ?? 0) / 1000) Kbps OUT:\(bytesToKbps(currentOut)) Kbps 總計OUT:\(bytesToKbps(report.totalBytesOut)) Kbps"
        )
    }

    private func updateAvgOutBps(latest: Double) {
        let now = Date()
        if let previous = avgOutBps, let lastTime = lastAvgUpdateTime {
            let deltaTime = now.timeIntervalSince(lastTime)
            let alphaTimeAdjusted = 1 - exp(-deltaTime / tau)
            avgOutBps = alphaTimeAdjusted * latest + (1 - alphaTimeAdjusted) * previous
        } else {
            avgOutBps = latest
        }
        lastAvgUpdateTime = now
    }

    private func bytesToKbps(_ bytes: Int) -> Int {
        return Int(Double(bytes * 8) / 1000.0)
    }
}
