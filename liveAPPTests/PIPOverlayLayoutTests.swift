import Testing
@testable import liveAPP

struct PIPOverlayLayoutTests {
    @Test func rowsStartBelowSystemButtonsAndStayOrdered() {
        #expect(PIPOverlayLayout.controlBandHeight == 36)
        #expect(PIPOverlayLayout.statusRowY(compact: false) >= PIPOverlayLayout.controlBandHeight)
        #expect(PIPOverlayLayout.nowTimeY(compact: false) > PIPOverlayLayout.statusRowY(compact: false))
        #expect(PIPOverlayLayout.noticeY(compact: false) > PIPOverlayLayout.nowTimeY(compact: false))
        #expect(PIPOverlayLayout.minimumChatTopMargin(compact: false) > PIPOverlayLayout.noticeY(compact: false))
    }

    @Test func compactRowsReclaimTheControlBandSpace() {
        #expect(PIPOverlayLayout.statusRowY(compact: true) == 12)
        #expect(PIPOverlayLayout.nowTimeY(compact: true) == 34)
        #expect(PIPOverlayLayout.noticeY(compact: true) == 54)
        #expect(PIPOverlayLayout.minimumChatTopMargin(compact: true) == 76)
        #expect(PIPOverlayLayout.statusRowY(compact: true) < PIPOverlayLayout.statusRowY(compact: false))
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
        #expect(PIPOverlayLayout.chatTopMargin(canvasHeight: 200, compact: false) == PIPOverlayLayout.minimumChatTopMargin(compact: false))
        #expect(PIPOverlayLayout.chatTopMargin(canvasHeight: 200, compact: true) == PIPOverlayLayout.minimumChatTopMargin(compact: true))
        #expect(abs(PIPOverlayLayout.chatTopMargin(canvasHeight: 480, compact: false) - 480 * 0.26) < 0.000001)
    }
}
