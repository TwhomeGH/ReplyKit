import Foundation

/// 一次 A/V 內容延遲取樣；秒為單位，nil 表示該階段尚未取得。
struct AVLagObservation: Codable, Equatable, Sendable {
    var session: String
    var sampledAt: Date
    var videoPTS: Double?
    var audioPTS: Double?
    var videoContentAge: Double?
    var videoIdleAge: Double?
    var audioContentAge: Double?
    var videoQueueAge: Double?
    var videoQueueOldestAge: Double?
    var videoProcessAge: Double?
    var videoSourceAge: Double?
    var sourcePTSDelta: Double?
    /// 相對本 session 第一筆有效 `sourcePTSDelta` 的累積變化；負值代表音訊 PTS 相對影片持續往後。
    var sourcePTSDeltaDrift: Double?
    /// 上述漂移換算成每分鐘變化；取樣時間太短時為 nil。
    var sourcePTSDeltaPerMinute: Double?
    /// 音訊 host-minus-PTS 減影片 host-minus-PTS；用來觀察來源時鐘漂移。
    var avClockDrift: Double?
    /// stable / drifting / jumped；只是診斷，不直接修正時間戳。
    var avSyncState: String?
    var videoQueue: String?
    var contentAgeJump: Double?
    var videoFrames = 0
    var audioFrames = 0

    /// 單行日誌；數值保留六位小數，unknown 不假裝成 0。
    var logLine: String {
        func number(_ value: Double?) -> String {
            value.map { String(format: "%.6f", $0) } ?? "unknown"
        }
        return "videoPTS=\(number(videoPTS)) audioPTS=\(number(audioPTS)) "
            + "videoContentAge=\(number(videoContentAge)) videoIdleAge=\(number(videoIdleAge)) audioContentAge=\(number(audioContentAge)) "
            + "videoQueueAge=\(number(videoQueueAge)) videoQueueOldestAge=\(number(videoQueueOldestAge)) "
            + "videoProcessAge=\(number(videoProcessAge)) "
            + "videoSourceAge=\(number(videoSourceAge)) sourcePTSDelta=\(number(sourcePTSDelta)) "
            + "deltaDrift=\(number(sourcePTSDeltaDrift)) deltaPerMin=\(number(sourcePTSDeltaPerMinute)) "
            + "clockDrift=\(number(avClockDrift)) syncState=\(avSyncState ?? "unknown") "
            + "jump=\(number(contentAgeJump)) frames=\(videoFrames)/\(audioFrames) "
            + "queue=\(videoQueue ?? "unknown")"
    }
}

/// 只保存純量與最近摘要；影片 worker 與音訊 worker 可並行寫入。
final class AVLagDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var videoPTS: Double?
    private var audioPTS: Double?
    private var videoQueueAge: Double?
    private var videoQueueOldestAge: Double?
    private var videoProcessAge: Double?
    private var videoSourceAge: Double?
    private var videoContentAge: Double?
    private var audioContentAge: Double?
    private var videoQueue: String?
    private var lastObservedContentAge: Double?
    private var pendingJump: Double?
    private var videoFrames = 0
    private var audioFrames = 0
    private var lastVideoAt: Double?
    private var firstSourceDelta: Double?
    private var firstSourceDeltaAt: Double?
    private var lastSourceDelta: Double?
    private var lastSourceDeltaAt: Double?

    /// 影片從 SCStream 交給 worker 時呼叫；contentAge 是回呼到達時間減來源 PTS。
    func recordVideo(arrival: Double, pts: Double, at now: Double,
                     queue: String, queueOldestAge: Double?) {
        lock.lock(); defer { lock.unlock() }
        guard arrival.isFinite, pts.isFinite, now.isFinite else { return }
        let age = arrival - pts
        if let previous = lastObservedContentAge, abs(age - previous) >= 1 {
            pendingJump = age - previous
        }
        lastObservedContentAge = age
        videoFrames += 1
        videoPTS = pts
        videoContentAge = age
        videoQueueAge = max(0, now - arrival)
        videoQueueOldestAge = queueOldestAge
        videoQueue = queue
        lastVideoAt = now
    }

    /// 影片加工完成時呼叫；processAge 是從回呼到加工完成的時間。
    func recordVideoProcessed(arrival: Double, pts: Double, at now: Double,
                              queue: String, queueOldestAge: Double?) {
        lock.lock(); defer { lock.unlock() }
        guard arrival.isFinite, pts.isFinite, now.isFinite else { return }
        videoProcessAge = max(0, now - arrival)
        videoSourceAge = max(0, now - pts)
        if let queueOldestAge { videoQueueOldestAge = queueOldestAge }
        videoQueue = queue
        lastVideoAt = now
    }

    /// 系統音訊（track 0）回呼；麥克風不併入 A/V 來源偏移。
    func recordAudio(arrival: Double, pts: Double, at now: Double, isMic: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !isMic, arrival.isFinite, pts.isFinite, now.isFinite else { return }
        audioFrames += 1
        audioPTS = pts
        audioContentAge = arrival - pts
    }

    /// 取樣並消耗一次階梯事件；沒有影片資料時回傳 nil，不以零冒充。
    func snapshot(session: String, now: Double, sampledAt: Date = Date()) -> AVLagObservation? {
        lock.lock(); defer { lock.unlock() }
        guard lastVideoAt != nil else { return nil }
        let sourceDelta: Double?
        if let videoPTS, let audioPTS, videoPTS.isFinite, audioPTS.isFinite {
            sourceDelta = videoPTS - audioPTS
        } else {
            sourceDelta = nil
        }

        if let sourceDelta {
            if firstSourceDelta == nil {
                firstSourceDelta = sourceDelta
                firstSourceDeltaAt = now
            }
        }
        let sourceDeltaDrift = sourceDelta.flatMap { current in
            firstSourceDelta.map { current - $0 }
        }
        let sourceDeltaPerMinute: Double?
        if let sourceDeltaDrift, let firstSourceDeltaAt, now > firstSourceDeltaAt {
            sourceDeltaPerMinute = sourceDeltaDrift / ((now - firstSourceDeltaAt) / 60)
        } else {
            sourceDeltaPerMinute = nil
        }
        let clockDrift: Double?
        if let audioContentAge, let videoContentAge {
            clockDrift = audioContentAge - videoContentAge
        } else {
            clockDrift = nil
        }
        var syncState: String?
        if let sourceDelta {
            // 100 ms 以上的變化只在短時間內視為跳變；累積 60 秒的變化
            // 應標成 drifting，不要讓一次正常取樣窗口掩蓋漂移趨勢。
            let changedQuickly = lastSourceDeltaAt.map { now - $0 < 10 } ?? false
            let jumped = changedQuickly
                && (lastSourceDelta.map { abs(sourceDelta - $0) >= 0.100 } ?? false)
            let drifting = abs(sourceDeltaDrift ?? 0) >= 0.080
                || abs(clockDrift ?? 0) >= 0.080
            syncState = jumped ? "jumped" : (drifting ? "drifting" : "stable")
        }
        if sourceDelta != nil {
            lastSourceDelta = sourceDelta
            lastSourceDeltaAt = now
        }

        let observation = AVLagObservation(
            session: session,
            sampledAt: sampledAt,
            videoPTS: videoPTS,
            audioPTS: audioPTS,
            videoContentAge: videoContentAge,
            videoIdleAge: lastVideoAt.map { max(0, now - $0) },
            audioContentAge: audioContentAge,
            videoQueueAge: videoQueueAge,
            videoQueueOldestAge: videoQueueOldestAge,
            videoProcessAge: videoProcessAge,
            videoSourceAge: videoSourceAge,
            sourcePTSDelta: sourceDelta,
            sourcePTSDeltaDrift: sourceDeltaDrift,
            sourcePTSDeltaPerMinute: sourceDeltaPerMinute,
            avClockDrift: clockDrift,
            avSyncState: syncState,
            videoQueue: videoQueue,
            contentAgeJump: pendingJump,
            videoFrames: videoFrames,
            audioFrames: audioFrames)
        pendingJump = nil
        return observation
    }

    /// 讓裝置頁在沒有新取樣時也能判斷資料是否過期。
    var lastVideoArrival: Double? {
        lock.lock(); defer { lock.unlock() }
        return lastVideoAt
    }
}
