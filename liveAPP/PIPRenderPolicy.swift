import Foundation

/// PiP 更新頻率決策；純計算，不建立計時器或讀寫使用者設定。
enum PIPRenderPolicy {
    /// 保活模式預設更新間隔，單位為秒。
    static let defaultKeepaliveSeconds = 5.0
    /// 預設保活頻率，單位為每秒幀數。
    static let keepaliveFPS = 1.0 / defaultKeepaliveSeconds

    /// 無效設定回復預設；限制更新間隔，避免零延遲忙迴圈。
    static func keepaliveSeconds(_ value: Double) -> Double {
        value.isFinite ? min(60, max(1, value)) : defaultKeepaliveSeconds
    }
    /// 聊天室沒有近期活動時的頻率。
    static let idleFPS = 2.0
    /// 訊息更新或贊助疊加顯示時的頻率。
    static let activeFPS = 6.0
    /// 聊天室捲動動畫期間的頻率。
    static let animationFPS = 16.0

    /// 將 FPS 換算為秒；非有限或非正值使用聊天室閒置頻率。
    /// - Parameter fps: 每秒幀數。
    /// - Returns: 正且有限的更新間隔。
    static func interval(for fps: Double) -> TimeInterval {
        1.0 / (fps.isFinite && fps > 0 ? fps : idleFPS)
    }

    /// 決定下次排程頻率；保活不受聊天活動影響，贊助疊加暫時使用 activeFPS。
    /// - Parameters:
    ///   - keepalive: 是否為低頻保活模式。
    ///   - overlay: 是否正在顯示贊助疊加。
    ///   - animating: 聊天室是否正在捲動。
    ///   - pendingMessages: 是否有待顯示訊息。
    ///   - recentlyActive: 是否仍在活動頻率冷卻期間。
    ///   - keepaliveInterval: 保活秒數，預設 5，正規化為 1–60。
    /// - Returns: 每秒幀數，不代表實測繪製速度。
    static func targetFPS(keepalive: Bool, overlay: Bool, animating: Bool,
                          pendingMessages: Bool, recentlyActive: Bool, keepaliveInterval: Double = defaultKeepaliveSeconds) -> Double {
        if keepalive { return overlay ? activeFPS : 1.0 / keepaliveSeconds(keepaliveInterval) }
        if animating { return animationFPS }
        return overlay || pendingMessages || recentlyActive ? activeFPS : idleFPS
    }
}

/// 取消後的回呼即使遇到新工作階段也不得恢復有效。
struct PIPRenderGeneration {
    /// 目前排程世代，只能透過 invalidate 前進。
    private(set) var value: UInt64 = 0

    /// 作廢既有回呼並回傳新世代識別。
    @discardableResult
    mutating func invalidate() -> UInt64 {
        value &+= 1
        return value
    }

    /// 判斷回呼是否仍屬於目前排程。
    func accepts(_ token: UInt64) -> Bool { token == value }
}
