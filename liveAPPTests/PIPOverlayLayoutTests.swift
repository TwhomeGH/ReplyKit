import Testing
@testable import liveAPP

struct PIPOverlayLayoutTests {
    @Test func rowsStartBelowSystemButtonsAndStayOrdered() {
        #expect(PIPOverlayLayout.controlBandHeight == 36)
        #expect(PIPOverlayLayout.statusRowY >= PIPOverlayLayout.controlBandHeight)
        #expect(PIPOverlayLayout.nowTimeY > PIPOverlayLayout.statusRowY)
        #expect(PIPOverlayLayout.noticeY > PIPOverlayLayout.nowTimeY)
        #expect(PIPOverlayLayout.minimumChatTopMargin > PIPOverlayLayout.noticeY)
    }

    @Test func statusRowUsesContentWidthBelowTheControlBand() {
        // 300 寬只扣內容左右邊距，不再扣系統按鈕。
        #expect(PIPOverlayLayout.statusRowAvailableWidth(canvasWidth: 300) == 276)
    }

    @Test func statusRowDropsIconBeforeViewer() {
        let plan = PIPOverlayLayout.statusRowPlan(availableWidth: 276,
                                                  iconWidth: 17, elapsedWidth: 67,
                                                  statusWidth: 130, viewerWidth: 56)
        #expect(!plan.drawIcon)
        #expect(plan.drawViewer)
        #expect(plan.usedWidth <= 276)
    }

    @Test func statusRowKeepsIconWhenItFits() {
        let plan = PIPOverlayLayout.statusRowPlan(availableWidth: 276,
                                                  iconWidth: 17, elapsedWidth: 67,
                                                  statusWidth: 0, viewerWidth: 0)
        #expect(plan.drawIcon)
        #expect(!plan.drawViewer)
        #expect(plan.usedWidth == 88)
    }

    @Test func longStatusDropsViewer() {
        let plan = PIPOverlayLayout.statusRowPlan(availableWidth: 276,
                                                  iconWidth: 17, elapsedWidth: 67,
                                                  statusWidth: 200, viewerWidth: 56)
        #expect(!plan.drawIcon)
        #expect(!plan.drawViewer)
        #expect(plan.usedWidth <= 276)
    }

    @Test func chatTopRespectsMinimumMargin() {
        #expect(PIPOverlayLayout.chatTopMargin(canvasHeight: 200) == PIPOverlayLayout.minimumChatTopMargin)
        #expect(abs(PIPOverlayLayout.chatTopMargin(canvasHeight: 480) - 480 * 0.26) < 0.000001)
    }
}
