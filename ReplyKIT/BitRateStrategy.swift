//
//  BitRateStrategy.swift
//  liveAPP
//
//  Created by user on 2025/10/29.
//

import HaishinKit
import Foundation

// MARK: 動態碼率控制
final actor MyStreamBitRateStrategy: @preconcurrency StreamBitRateStrategy {
    var mamimumVideoBitRate: Int

    var mamimumAudioBitRate: Int


    // 暖機期設置
    private let warmupDuration: TimeInterval = 10.0 // 秒
    private var startTime: Date?


    private let minBitrate = 1_500_000       // 最低 1500 kbps
    private let stepUp: Double = 1.05      // 緩升 5%
    private let stepDown: Double = 0.99    // 緩降 1%

    private var avgOutBps: Double? //EMA平滑曲線

    var lastBitrateChangeTime: Date? = nil
    let minBitrateHoldDuration: TimeInterval = 3.0 // 秒

    // 新增：最後一次收到 status 的時間
    private var lastStatusTimestamp: Date?

    // 新增：斷線 callback
    private var onDisconnect: (() -> Void)?

    func setOnDisconnect(_ closure: @escaping () -> Void) {
        self.onDisconnect = closure
    }

    // 宣告歷史陣列
    var avgOutBpsHistory: [Double] = []

    var ChangeBit = false


    func isChangBit(_ status:Bool = false){
        self.ChangeBit = status
    }



    private var lastAvgUpdateTime: Date? = nil
    private let tau: TimeInterval = 3.0 // 平滑時間常數 (秒)

    func updateAvgOutBps(latest: Double) {
        let now = Date()
        if let previous = avgOutBps, let lastTime = lastAvgUpdateTime {
            let deltaTime = now.timeIntervalSince(lastTime)
            // 計算時間加權 alpha
            let alphaTimeAdjusted = 1 - exp(-deltaTime / tau)
            avgOutBps = alphaTimeAdjusted * latest + (1 - alphaTimeAdjusted) * previous
        } else {
            avgOutBps = latest // 第一筆資料
        }
        lastAvgUpdateTime = now
    }
    
    init(videoBitRate: Int = 4_000_000,
         audioBitRate: Int = 128_000 ) {
        self.mamimumVideoBitRate = videoBitRate
        self.mamimumAudioBitRate = audioBitRate
            self.startTime = Date()


    }

    // 或者重置為當前時間
    func refreshStatusTimestamp() {
        lastStatusTimestamp = Date()
    }

    // 新增方法封裝修改
      func updateAudioBitRate(to value: Int) {
          self.mamimumAudioBitRate = value
      }
    func updateVideoBitRate(to value: Int) {
        self.mamimumVideoBitRate = value
    }

    private func bytesToKbps(_ bytes: Int) -> Int {
        return Int(Double(bytes * 8) / 1000.0)
    }

    // 新增：檢查超時，超過 threshold 就呼叫 onDisconnect
    func checkDisconnect(timeout: TimeInterval) async {
        if let last = lastStatusTimestamp, Date().timeIntervalSince(last) > timeout {
            onDisconnect?()
        }
    }



    func applyVideoBitrate(_ newBitRate: Int, to stream: some HaishinKit.StreamConvertible) async {
        var v = await stream.videoSettings
        guard v.bitRate != newBitRate else { return } // 避免同值也一直 set

        v.bitRate = newBitRate
        try? await stream.setVideoSettings(v)

        lastBitrateChangeTime = Date()        // ✅ 關鍵：更新冷卻時間
        avgOutBpsHistory.removeAll()          // ✅ 可選：避免用舊歷史立刻二次觸發
    }


    func adjustBitrate(_ event: HaishinKit.NetworkMonitorEvent, stream: some HaishinKit.StreamConvertible) async {
        switch event {
        case .status(let report):

            lastStatusTimestamp = Date()  // ✅ 記錄最後一次收到 status 的時間
            // let currentInt = report.currentBytesInPerSecond
             let currentOut = report.currentBytesOutPerSecond

            updateAvgOutBps(latest: Double(report.currentBytesOutPerSecond * 8))



             //let totalInt = report.totalBytesIn
             let totalOut = report.totalBytesOut

            // 暖機期檢查
            if let start = startTime, Date().timeIntervalSince(start) < warmupDuration {
                sendlog(message: "暖機期中，不調整碼率，AVG: \((avgOutBps ?? 0)/1000) Kbps")
                return
            }

        


            let newBitV = await stream.videoSettings
            let VBitRate = newBitV.bitRate



            let BitInfo=[
               "BitRate統計:",
               "VideoBit:\(VBitRate/1000) Kbps",
               //"IN:\(bitToMbps(currentInt)) Kbps",
               "AVG: \((avgOutBps ?? 0)/1000) Kbps",
               "OUT:\(bytesToKbps(currentOut)) Kbps",


               //"CQB:\(report.currentQueueBytesOut)",
               //"\nTotal IN:\(bitToMbps(totalInt)) Kbps",
               "總計OUT:\(bytesToKbps(totalOut)) Kbps"

            ]
            // 根據即時統計值判斷
            sendlog(
                message:BitInfo.joined(separator: " ")
            )




            // 若網路No穩定且低於最大值，緩 30%

            // 每次收到 status 事件更新
            avgOutBpsHistory.append(avgOutBps ?? Double(VBitRate))

            // 只保留最近 N 個
            if avgOutBpsHistory.count > 10 {
                avgOutBpsHistory.removeFirst()
            }


            if let lastChange = lastBitrateChangeTime,
               Date().timeIntervalSince(lastChange) < minBitrateHoldDuration {
                // 離上次碼率調整時間還太短，不做調整
                sendlog(message: "📌 保持碼率不變，距上次調整 < \(minBitrateHoldDuration)s : \(VBitRate)")
                return
            }




            if ChangeBit == false {
                
                return
            }
            // 緩降
            // 判斷是否連續多次低於阈值才降碼率
            
            if avgOutBpsHistory.filter({ $0 < Double(VBitRate) * 0.75 }).count >= 7 {

                let res = max(minBitrate, Int(Double(VBitRate) * 0.9))  // ✅ 降 10%



                sendlog(message: "📉 Bitrate 降至 : \(newBitV.bitRate) : \(newBitV.bitRate / 1000) Kbps")

                await applyVideoBitrate(res, to: stream)

            }


            // 緩升
            else if Int(avgOutBps ?? 0) > Int(Double(VBitRate) * 0.75), VBitRate < mamimumVideoBitRate {

                let target = min(mamimumVideoBitRate , Int(Double(VBitRate) * stepUp))

                let res = max(minBitrate, target) // ✅ 同樣保護

                sendlog(message: "📈 Bitrate 回升至 \(newBitV.bitRate / 1000) Kbps")

                await applyVideoBitrate(res, to: stream)

            }

        case .publishInsufficientBWOccured( _):
            // 網路不穩時降碼率 -30%

            if ChangeBit == false {
                sendlog(message: "不穩定 已停用調整碼率!")
                return
            }

            let newBitV=await stream.videoSettings

            // 用平均出流量或當前出流量作為基準
            let measuredBps = avgOutBps ?? Double(newBitV.bitRate)

            // 使用短期 EMA 或平滑歷史
            let smoothBps = 0.7 * (avgOutBps ?? Double(newBitV.bitRate)) + 0.3 * measuredBps

            // 計算新 bitrate，但不低於 minBitrate
            let res = max(
                minBitrate,
                Int(smoothBps * 0.85)
            ) // 例如降到 85% 的平均出流量

            sendlog(message: "📉 Bitrate 網路不穩，調整至: \(newBitV.bitRate / 1000) Kbps")

            await applyVideoBitrate(res, to: stream)

        case .reset:
            // 回復最大碼率

            let newBit=await stream.videoSettings

            let res = mamimumVideoBitRate

            sendlog(message: "BitRateReset: \(newBit.bitRate)")

            await applyVideoBitrate(res, to: stream)

        }
    }



}

