import HaishinKit
import Foundation

// MARK: 動態碼率控制
final actor MyStreamBitRateStrategy: @preconcurrency StreamBitRateStrategy {
    var mamimumVideoBitRate: Int
    var mamimumAudioBitRate: Int

    // 暖機期設置
    private let warmupDuration: TimeInterval = 10.0
    private var startTime: Date?

    private let minBitrate = 1_500_000
    private let stepUp: Double = 1.05
    private var avgOutBps: Double?

    var lastBitrateChangeTime: Date? = nil
    let minBitrateHoldDuration: TimeInterval = 3.0

    private var lastStatusTimestamp: Date?
    private var onDisconnect: (() -> Void)?

    func setOnDisconnect(_ closure: @escaping () -> Void) {
        self.onDisconnect = closure
    }

    var ChangeBit = false

    func isChangBit(_ status: Bool = false) {
        self.ChangeBit = status
    }

    // ring buffer 取代 Array.removeFirst()，避免 O(n) 位移
    private var historyBuffer = RingBuffer<Double>(capacity: 10)

    private var lastAvgUpdateTime: Date? = nil
    private let tau: TimeInterval = 3.0

    func updateAvgOutBps(latest: Double) {
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

    // 緩存當前 video bitrate，避免每次 await stream.videoSettings
    private var currentVideoBitRate: Int

    init(videoBitRate: Int = 6_000_000,
         audioBitRate: Int = 128_000) {
        self.mamimumVideoBitRate = videoBitRate
        self.mamimumAudioBitRate = audioBitRate
        self.currentVideoBitRate = videoBitRate
        self.startTime = Date()
    }

    func refreshStatusTimestamp() {
        lastStatusTimestamp = Date()
    }

    func updateAudioBitRate(to value: Int) {
        self.mamimumAudioBitRate = value
    }
    func updateVideoBitRate(to value: Int) {
        self.mamimumVideoBitRate = value
    }

    private func bytesToKbps(_ bytes: Int) -> Int {
        return Int(Double(bytes * 8) / 1000.0)
    }

    private var disconnectFired = false

    func checkDisconnect(timeout: TimeInterval) async {
        guard !disconnectFired else { return }
        if let last = lastStatusTimestamp, Date().timeIntervalSince(last) > timeout {
            disconnectFired = true
            onDisconnect?()
        }
    }

    func resetDisconnectCheck() {
        disconnectFired = false
    }

    func applyVideoBitrate(_ newBitRate: Int, to stream: some HaishinKit.StreamConvertible) async {
        var v = await stream.videoSettings
        guard v.bitRate != newBitRate else { return }
        v.bitRate = newBitRate
        try? await stream.setVideoSettings(v)
        currentVideoBitRate = newBitRate
        lastBitrateChangeTime = Date()
        historyBuffer.removeAll()
    }

    // 統計模式日誌節流：每 N 次 status 事件才寫一次 log
    private var statsLogCounter: Int = 0
    private let statsLogInterval: Int = 10

    func adjustBitrate(_ event: HaishinKit.NetworkMonitorEvent, stream: some HaishinKit.StreamConvertible) async {
        switch event {
        case .status(let report):
            lastStatusTimestamp = Date()
            let currentOut = report.currentBytesOutPerSecond
            updateAvgOutBps(latest: Double(report.currentBytesOutPerSecond * 8))
            let totalOut = report.totalBytesOut

            if let start = startTime, Date().timeIntervalSince(start) < warmupDuration {
                sendlog(message: "暖機期中，不調整碼率，AVG: \((avgOutBps ?? 0)/1000) Kbps")
                return
            }

            // 統計專用模式：跳過所有調整邏輯，僅保留必要統計 + 節流日誌
            guard ChangeBit else {
                statsLogCounter += 1
                if statsLogCounter >= statsLogInterval {
                    statsLogCounter = 0
                    sendlog(
                        message: "BitRate統計: VideoBit:\(currentVideoBitRate/1000) Kbps AVG: \((avgOutBps ?? 0)/1000) Kbps OUT:\(bytesToKbps(currentOut)) Kbps 總計OUT:\(bytesToKbps(totalOut)) Kbps"
                    )
                }
                return
            }

            // 以下為調整模式
            sendlog(
                message: "BitRate統計: VideoBit:\(currentVideoBitRate/1000) Kbps AVG: \((avgOutBps ?? 0)/1000) Kbps OUT:\(bytesToKbps(currentOut)) Kbps 總計OUT:\(bytesToKbps(totalOut)) Kbps"
            )

            historyBuffer.push(avgOutBps ?? Double(currentVideoBitRate))

            if let lastChange = lastBitrateChangeTime,
                Date().timeIntervalSince(lastChange) < minBitrateHoldDuration {
                sendlog(message: "📌 保持碼率不變，距上次調整 < \(minBitrateHoldDuration)s : \(currentVideoBitRate)")
                return
            }

            if historyBuffer.count(where: { $0 < Double(currentVideoBitRate) * 0.75 }) >= 7 {
                let res = max(minBitrate, Int(Double(currentVideoBitRate) * 0.9))
                sendlog(message: "📉 Bitrate 降至 : \(res) : \(res / 1000) Kbps")
                await applyVideoBitrate(res, to: stream)
            } else if Int(avgOutBps ?? 0) > Int(Double(currentVideoBitRate) * 0.75), currentVideoBitRate < mamimumVideoBitRate {
                let target = min(mamimumVideoBitRate, Int(Double(currentVideoBitRate) * stepUp))
                let res = max(minBitrate, target)
                sendlog(message: "📈 Bitrate 回升至 \(res / 1000) Kbps")
                await applyVideoBitrate(res, to: stream)
            }

        case .publishInsufficientBWOccured(_):
            guard ChangeBit else {
                sendlog(message: "不穩定 已停用調整碼率!")
                return
            }

            let measuredBps = avgOutBps ?? Double(currentVideoBitRate)
            let smoothBps = 0.7 * (avgOutBps ?? Double(currentVideoBitRate)) + 0.3 * measuredBps
            let res = max(minBitrate, Int(smoothBps * 0.85))

            sendlog(message: "📉 Bitrate 網路不穩，調整至: \(res / 1000) Kbps")
            await applyVideoBitrate(res, to: stream)

        case .reset:
            let res = mamimumVideoBitRate
            sendlog(message: "BitRateReset: \(currentVideoBitRate) -> \(res)")
            await applyVideoBitrate(res, to: stream)
        }
    }
}

// MARK: - 固定容量 ring buffer，O(1) push / count
private struct RingBuffer<Element> {
    private var storage: [Element?]
    private var readIndex = 0
    private var writeIndex = 0
    private(set) var count = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    mutating func push(_ element: Element) {
        storage[writeIndex] = element
        writeIndex = (writeIndex + 1) % capacity
        if count < capacity {
            count += 1
        } else {
            readIndex = (readIndex + 1) % capacity
        }
    }

    mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        readIndex = 0
        writeIndex = 0
        count = 0
    }

    func count(where predicate: (Element) throws -> Bool) rethrows -> Int {
        var matched = 0
        for i in 0..<count {
            let idx = (readIndex + i) % capacity
            if let value = storage[idx], try predicate(value) {
                matched += 1
            }
        }
        return matched
    }
}
