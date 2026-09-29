import Foundation

enum PIPRenderPolicy {
    static let keepaliveFPS = 0.2
    static let idleFPS = 2.0
    static let activeFPS = 6.0
    static let animationFPS = 16.0

    static func interval(for fps: Double) -> TimeInterval {
        1.0 / (fps.isFinite && fps > 0 ? fps : idleFPS)
    }

    static func targetFPS(keepalive: Bool, overlay: Bool, animating: Bool,
                          pendingMessages: Bool, recentlyActive: Bool) -> Double {
        if keepalive { return overlay ? activeFPS : keepaliveFPS }
        if animating { return animationFPS }
        return overlay || pendingMessages || recentlyActive ? activeFPS : idleFPS
    }
}

// A cancelled callback must remain invalid even after another session starts.
struct PIPRenderGeneration {
    private(set) var value: UInt64 = 0

    @discardableResult
    mutating func invalidate() -> UInt64 {
        value &+= 1
        return value
    }

    func accepts(_ token: UInt64) -> Bool { token == value }
}
