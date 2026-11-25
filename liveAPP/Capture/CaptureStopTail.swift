import Foundation

/// 停止收播時的最後來源 PTS 差；用來驗證「先停畫面、再停音訊」。
/// 只比較來源時間軸，不代表實際檔案尾端或播放器行為。
struct CaptureStopTail: Sendable, Equatable {
    /// 最後一個影片來源 PTS（秒）。
    let videoPTS: Double?
    /// 最後一個系統音訊來源 PTS（秒）。
    let audioPTS: Double?
    /// 最後一個麥克風來源 PTS（秒）；不列入主要判定。
    let micPTS: Double?

    /// 音訊最後 PTS 減影片最後 PTS；正值代表音訊比影片晚結束。
    var audioTailSeconds: Double? {
        guard let videoPTS, let audioPTS else { return nil }
        return audioPTS - videoPTS
    }

    /// 麥克風最後 PTS 減影片最後 PTS；只供診斷。
    var micTailSeconds: Double? {
        guard let videoPTS, let micPTS else { return nil }
        return micPTS - videoPTS
    }

    /// 收播尾端判定。
    enum Verdict: String, Sendable {
        /// 音訊比影片早超過 1 秒停止；對應「音訊已靜音、畫面還在動」。
        case audioStoppedEarly
        /// 音訊比影片晚超過 1 秒停止。
        case audioContinuedAfterVideo
        /// 兩者差距在 1 秒內。
        case withinOneSecond
        /// 缺少其中一個時間軸。
        case unknown
    }

    /// 以 1 秒容差判斷；未知時間軸不假裝正常。
    var verdict: Verdict {
        guard let tail = audioTailSeconds else { return .unknown }
        if tail < -1 { return .audioStoppedEarly }
        if tail > 1 { return .audioContinuedAfterVideo }
        return .withinOneSecond
    }

    /// 單行日誌；unknown 顯示 unknown，不寫成 0。
    var logLine: String {
        func number(_ value: Double?) -> String {
            value.map { String(format: "%.6f", $0) } ?? "unknown"
        }
        return "videoLastPTS=\(number(videoPTS)) audioLastPTS=\(number(audioPTS)) "
            + "micLastPTS=\(number(micPTS)) audioTailSeconds=\(number(audioTailSeconds)) "
            + "micTailSeconds=\(number(micTailSeconds)) acceptanceSeconds=1.000000 "
            + "verdict=\(verdict.rawValue)"
    }
}
