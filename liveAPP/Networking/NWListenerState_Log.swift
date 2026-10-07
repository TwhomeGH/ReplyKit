import Network

/// Listener 狀態的日誌表示；不參與重試或狀態判斷。
extension NWListener.State {
    /// 保留 waiting／failed 的原始錯誤，未知系統狀態顯示 unknown。
    var stateString: String {
        switch self {
        case .setup:
            return "setup"
        case .waiting(let error):
            return "waiting (\(error))"
        case .ready:
            return "ready"
        case .failed(let error):
            return "failed (\(error))"
        case .cancelled:
            return "cancelled"
        @unknown default:
            return "unknown"
        }
    }
}
