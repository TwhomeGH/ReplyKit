import Testing
@testable import liveAPP

struct PIPOverlayLayoutTests {
    @Test func controlBandClearsSystemButtonsAndKeepsRowsOrdered() {
        #expect(PIPOverlayLayout.controlBandHeight == PIPOverlayLayout.sideInset)
        #expect(PIPOverlayLayout.controlBandHeight >= 52)
        #expect(PIPOverlayLayout.nowTimeY >= PIPOverlayLayout.controlBandHeight)
        #expect(PIPOverlayLayout.noticeY > PIPOverlayLayout.nowTimeY)
        #expect(PIPOverlayLayout.minimumChatTopMargin > PIPOverlayLayout.noticeY)
    }

    @Test func statusRowDropsIconBeforeViewer() {
        // 300 寬減左右各 56 保留區，剩 188。
        let available = PIPOverlayLayout.statusRowAvailableWidth(canvasWidth: 300)
        #expect(available == 188)

        let plan = PIPOverlayLayout.statusRowPlan(availableWidth: available,
                                                  iconWidth: 17, elapsedWidth: 67,
                                                  statusWidth: 44, viewerWidth: 56)
        #expect(!plan.drawIcon)
        #expect(plan.drawViewer)
        #expect(plan.usedWidth <= available)
    }

    @Test func statusRowKeepsIconWhenItFits() {
        let plan = PIPOverlayLayout.statusRowPlan(availableWidth: 188,
                                                  iconWidth: 17, elapsedWidth: 67,
                                                  statusWidth: 0, viewerWidth: 0)
        #expect(plan.drawIcon)
        #expect(!plan.drawViewer)
        #expect(plan.usedWidth == 88)
    }

    @Test func longStatusDropsViewer() {
        let plan = PIPOverlayLayout.statusRowPlan(availableWidth: 188,
                                                  iconWidth: 17, elapsedWidth: 67,
                                                  statusWidth: 120, viewerWidth: 56)
        #expect(!plan.drawIcon)
        #expect(!plan.drawViewer)
    }

    @Test func chatTopRespectsMinimumMargin() {
        #expect(PIPOverlayLayout.chatTopMargin(canvasHeight: 200) == PIPOverlayLayout.minimumChatTopMargin)
        #expect(abs(PIPOverlayLayout.chatTopMargin(canvasHeight: 480) - 480 * 0.26) < 0.000001)
    }
}
