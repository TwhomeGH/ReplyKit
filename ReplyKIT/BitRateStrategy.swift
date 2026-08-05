import HaishinKit
import Foundation

// MARK: 碼率統計策略（僅統計，不做動態調整）
// 壅塞處理由 HaishinKit fork 內部的 SocketBackpressure（三級丟幀）負責，
// 此策略只負責收集 NetworkMonitor 統計並輸出節流日誌。
final actor MyStreamBitRateStrategy: @preconcurrency StreamBitRateStrategy {
    var mamimumVideoBitRate: Int
    var mamimumAudioBitRate: Int

    // 指數移動平均（bit/s），tau 控制平滑時間常數
    private var avgOutBps: Double?
    private var lastAvgUpdateTime: Date?
    private let tau: TimeInterval = 3.0

    // 統計日誌節流：每 N 次 status 事件才寫一次 log
    private var statsLogCounter: Int = 0
    private let statsLogInterval: Int = 10

    init(videoBitRate: Int = 6_000_000,
         audioBitRate: Int = 128_000) {
        self.mamimumVideoBitRate = videoBitRate
        self.mamimumAudioBitRate = audioBitRate
    }

    func adjustBitrate(_ event: HaishinKit.NetworkMonitorEvent, stream: some HaishinKit.StreamConvertible) async {
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
