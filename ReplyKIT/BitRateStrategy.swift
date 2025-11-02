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


    private let minBitrate = 2_000_000       // 最低 2000 kbps
    private let stepUp: Double = 1.05      // 緩升 5%
    private let stepDown: Double = 0.85    // 緩降 15%

    private var avgOutBps: Double? //EMA平滑曲線

    // 新增：最後一次收到 status 的時間
    private var lastStatusTimestamp: Date?

    // 新增：斷線 callback
    private var onDisconnect: (() -> Void)?

    func setOnDisconnect(_ closure: @escaping () -> Void) {
        self.onDisconnect = closure
    }



    func updateAvgOutBps(latest: Double) {
        let alpha = 0.2
        if let previous = avgOutBps {
            avgOutBps = alpha * latest + (1 - alpha) * previous
        } else {
            avgOutBps = latest // 第一筆資料直接當作初始值
        }
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

    func bitToKbps(_ bit:Int = 4_000_000) -> Int{
        return Int(Double(bit * 8 ) / 1000.0)
    }

    // 新增：檢查超時，超過 threshold 就呼叫 onDisconnect
    func checkDisconnect(timeout: TimeInterval) async {
        if let last = lastStatusTimestamp, Date().timeIntervalSince(last) > timeout {
            onDisconnect?()
        }
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

        


            var newBitV = await stream.videoSettings
            let VBitRate = newBitV.bitRate



            let BitInfo=[
               "BitRate統計:",
               "VideoBit:\(VBitRate/1000) Kbps",
               //"IN:\(bitToMbps(currentInt)) Kbps",
               "AVG: \((avgOutBps ?? 0)/1000) Kbps",
               "OUT:\(bitToKbps(currentOut)) Kbps",


               //"CQB:\(report.currentQueueBytesOut)",
               //"\nTotal IN:\(bitToMbps(totalInt)) Kbps",
               "總計OUT:\(bitToKbps(totalOut)) Kbps"

            ]
            // 根據即時統計值判斷
            sendlog(
                message:BitInfo.joined(separator: " ")
            )




            // 若網路No穩定且低於最大值，緩 30%

            // 緩降
            if Int(avgOutBps ?? 0) < Int(Double(VBitRate) * 0.5) {

                newBitV.bitRate=max(minBitrate, Int(Double(VBitRate) * stepDown))


                sendlog(message: "📉 Bitrate 降至 : \(newBitV.bitRate / 1000) Kbps")

                try? await stream.setVideoSettings(newBitV)
            }


            // 緩升
            else if Int(avgOutBps ?? 0) > Int(Double(VBitRate) * 0.95), VBitRate < mamimumVideoBitRate {

                newBitV.bitRate = min(mamimumVideoBitRate , Int(Double(VBitRate) * stepUp) )

                sendlog(message: "📈 Bitrate 回升至 \(newBitV.bitRate / 1000) Kbps")

                try? await stream.setVideoSettings(newBitV)


            }

        case .publishInsufficientBWOccured( _):
            // 網路不穩時降碼率 -30%

            var newBitV=await stream.videoSettings

            // 用平均出流量或當前出流量作為基準
            let measuredBps = avgOutBps ?? Double(newBitV.bitRate)

            // 計算新 bitrate，但不低於 minBitrate
            newBitV.bitRate = max(minBitrate, Int(measuredBps * 0.9)) // 例如降到 90% 的平均出流量

            sendlog(message: "📉 Bitrate 網路不穩，調整至: \(newBitV.bitRate / 1000) Kbps")


            try? await stream.setVideoSettings(newBitV)

        case .reset:
            // 回復最大碼率

            var newBit=await stream.videoSettings
            newBit.bitRate = mamimumVideoBitRate

            sendlog(message: "BitRateReset: \(newBit.bitRate)")

            try? await stream.setVideoSettings(newBit)
        }
    }



}

