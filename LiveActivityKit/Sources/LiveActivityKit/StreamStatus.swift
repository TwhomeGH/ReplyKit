public enum StreamStatus: Codable, Hashable {
    case live
    case ended
    case reconnecting(String)

    public var label: String {
        switch self {
        case .live: return "Live"
        case .ended: return "已結束"
        case .reconnecting: return "重新連線中"
        }
    }
}
