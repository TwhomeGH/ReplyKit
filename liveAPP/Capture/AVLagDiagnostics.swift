import Foundation

/// 一次 A/V 來源時間戳取樣（不是實際內容同步量測）；秒為單位，nil 表示該階段尚未取得。
struct AVLagObservation: Codable, Equatable, Sendable {
    /// AVLag 量測 session；同一場直播的樣本共用。
    var session: String
    /// 建立這筆樣本的 wall-clock 時間，不是 media PTS。
    var sampledAt: Date
    /// 最近一次影片來源回呼的 media PTS。
    var videoPTS: Double?
    /// 最近一次系統音訊回呼的 media PTS；麥克風不計入。
    var audioPTS: Double?
    /// 影片回呼到達時間減來源 PTS；是交付年齡，不是真正抓幀內容年齡。
    var videoContentAge: Double?
    /// 距離最近一次影片來源回呼的時間；長時間沒有新影格時增加。
    var videoIdleAge: Double?
    /// 音訊回呼到達時間減來源 PTS；不是口型同步誤差。
    var audioContentAge: Double?
    /// 距離最近一次音訊來源回呼的時間。
    var audioIdleAge: Double?
    /// 距離最近一次影片加工完成的時間；觀察 worker 是否停滯。
    var videoWorkerIdleAge: Double?
    /// 距離最近一次音訊加工完成的時間。
    var audioWorkerIdleAge: Double?
    /// 來源時鐘比對狀態；目前通常為 `unverified`，不代表已同步。
    var clockComparison: String? = "unverified"
    /// 內容同步量測狀態；目前為 `notMeasured`，不可解讀為同步正常。
    var contentSynchronization: String? = "notMeasured"
    /// 量測當下影格已在影片佇列停留的時間。
    var videoQueueAge: Double?
    /// 佇列中最舊影格的年齡；unknown 時為 nil。
    var videoQueueOldestAge: Double?
    /// 影片加工耗時：加工完成時間減回呼到達時間。
    var videoProcessAge: Double?
    /// 加工完成時間減來源 PTS；仍不是真正抓幀時間。
    var videoSourceAge: Double?
    /// 最新影片 PTS 減音訊 PTS；未做同幀配對，不能當 A/V 偏移結論。
    var sourcePTSDelta: Double?
    /// 相對本 session 第一筆有效 `sourcePTSDelta` 的累積變化；負值代表音訊 PTS 相對影片持續往後。
    var sourcePTSDeltaDrift: Double?
    /// 上述漂移換算成每分鐘變化；取樣時間太短時為 nil。
    var sourcePTSDeltaPerMinute: Double?
    /// 音訊 host-minus-PTS 減影片 host-minus-PTS；用來觀察來源時鐘漂移。
    var avClockDrift: Double?
    /// `unpairedObservation`／`stale`；未配對的觀測不判定影音同步。
    var avSyncState: String?
    /// 影片佇列的摘要文字，保留佇列／丟棄原因；不是時間量測。
    var videoQueue: String?
    /// 內容年齡相對上一筆的階梯變化；nil 表示沒有超過門檻的跳變。
    var contentAgeJump: Double?
    /// 本 session 累計的影片來源回呼數，不是輸出幀數。
    var videoFrames = 0
    /// 本 session 累計的音訊來源回呼數，不是輸出 packet 數。
    var audioFrames = 0

    /// 單行日誌；數值保留六位小數，unknown 不假裝成 0。
    var logLine: String {
        func number(_ value: Double?) -> String {
            value.map { String(format: "%.6f", $0) } ?? "unknown"
        }
        return "videoPTS=\(number(videoPTS)) audioPTS=\(number(audioPTS)) "
            + "videoContentAge=\(number(videoContentAge)) videoIdleAge=\(number(videoIdleAge)) audioContentAge=\(number(audioContentAge)) audioIdleAge=\(number(audioIdleAge)) videoWorkerIdleAge=\(number(videoWorkerIdleAge)) audioWorkerIdleAge=\(number(audioWorkerIdleAge)) "
            + "videoQueueAge=\(number(videoQueueAge)) videoQueueOldestAge=\(number(videoQueueOldestAge)) "
            + "videoProcessAge=\(number(videoProcessAge)) "
            + "videoSourceAge=\(number(videoSourceAge)) sourcePTSDelta=\(number(sourcePTSDelta)) "
            + "deltaDrift=\(number(sourcePTSDeltaDrift)) deltaPerMin=\(number(sourcePTSDeltaPerMinute)) "
            + "clockDrift=\(number(avClockDrift)) syncState=\(avSyncState ?? "unknown") clockComparison=\(clockComparison ?? "unknown") contentSync=\(contentSynchronization ?? "unknown") "
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
    private var lastAudioAt: Double?
    private var lastVideoAt: Double?
    private var lastVideoWorkerAt: Double?
    private var lastAudioWorkerAt: Double?
    private var firstSourceDelta: Double?
    private var firstSourceDeltaAt: Double?

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
        lastVideoAt = arrival
        lastVideoWorkerAt = now
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
        lastVideoWorkerAt = now
    }

    /// 系統音訊（track 0）回呼；麥克風不併入 A/V 來源偏移。
    func recordAudio(arrival: Double, pts: Double, at now: Double, isMic: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !isMic, arrival.isFinite, pts.isFinite, now.isFinite else { return }
        lastAudioAt = arrival
        lastAudioWorkerAt = now
        audioFrames += 1
        audioPTS = pts
        audioContentAge = arrival - pts
    }

    /// 取樣並消耗一次階梯事件；沒有影片資料時回傳 nil，不以零冒充。
    func snapshot(session: String, now: Double, sampledAt: Date = Date()) -> AVLagObservation? {
        lock.lock(); defer { lock.unlock() }
        guard lastVideoAt != nil, now.isFinite else { return nil }
        // 過期樣本只保留原始數值；恢復後另建基準，不延續停頓造成的假漂移。
        let fresh = [lastVideoAt, lastAudioAt].allSatisfy { time in
            guard let time else { return false }
            return now >= time && now - time <= 0.5
        }
        if !fresh {
            firstSourceDelta = nil
            firstSourceDeltaAt = nil
        }
        let sourceDelta: Double?
        if let videoPTS, let audioPTS, videoPTS.isFinite, audioPTS.isFinite {
            sourceDelta = videoPTS - audioPTS
        } else {
            sourceDelta = nil
        }

        if fresh, let sourceDelta {
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
        // 最新樣本未做 arrival 配對，因此不再用數值門檻宣判同步或漂移。
        let syncState = fresh ? "unpairedObservation" : "stale"

        let observation = AVLagObservation(
            session: session,
            sampledAt: sampledAt,
            videoPTS: videoPTS,
            audioPTS: audioPTS,
            videoContentAge: videoContentAge,
            videoIdleAge: lastVideoAt.map { max(0, now - $0) },
            audioContentAge: audioContentAge,
            audioIdleAge: lastAudioAt.map { max(0, now - $0) },
            videoWorkerIdleAge: lastVideoWorkerAt.map { max(0, now - $0) },
            audioWorkerIdleAge: lastAudioWorkerAt.map { max(0, now - $0) },
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

    /// 最近已送進 worker 的來源回呼時間；不以加工完成時間冒充來源更新。
    var lastVideoArrival: Double? {
        lock.lock(); defer { lock.unlock() }
        return lastVideoAt
    }
}
