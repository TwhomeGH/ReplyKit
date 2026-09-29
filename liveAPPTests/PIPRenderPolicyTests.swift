import Testing
@testable import liveAPP

struct PIPRenderPolicyTests {
    @Test func keepaliveIgnoresChatActivity() {
        let fps = PIPRenderPolicy.targetFPS(keepalive: true, overlay: false,
            animating: true, pendingMessages: true, recentlyActive: true)
        #expect(PIPRenderPolicy.interval(for: fps) == 5)
    }

    @Test func overlayReturnsToKeepaliveCadence() {
        #expect(PIPRenderPolicy.targetFPS(keepalive: true, overlay: true,
            animating: false, pendingMessages: false, recentlyActive: false) == 6)
        #expect(PIPRenderPolicy.targetFPS(keepalive: true, overlay: false,
            animating: false, pendingMessages: false, recentlyActive: true) == 0.2)
    }

    @Test func chatCanDecayAfterActivity() {
        #expect(PIPRenderPolicy.targetFPS(keepalive: false, overlay: false,
            animating: false, pendingMessages: false, recentlyActive: false) == 2)
        #expect(PIPRenderPolicy.targetFPS(keepalive: false, overlay: false,
            animating: true, pendingMessages: false, recentlyActive: false) == 16)
        #expect(PIPRenderPolicy.targetFPS(keepalive: false, overlay: false,
            animating: false, pendingMessages: true, recentlyActive: false) == 6)
    }

    @Test func cancelledCallbacksStayInvalidAfterRestart() {
        var generation = PIPRenderGeneration()
        let oldCallback = generation.invalidate()
        generation.invalidate() // Stop.
        let newCallback = generation.invalidate() // Restart.
        #expect(!generation.accepts(oldCallback))
        #expect(generation.accepts(newCallback))
        generation.invalidate() // Reschedule.
        #expect(!generation.accepts(newCallback))
    }

    @Test func invalidFPSHasFiniteDelay() {
        for fps in [0.0, -1.0, Double.nan, Double.infinity] {
            #expect(PIPRenderPolicy.interval(for: fps) == 0.5)
        }
    }
}
