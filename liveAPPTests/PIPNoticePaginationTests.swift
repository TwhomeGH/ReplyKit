import Testing
import UIKit
@testable import liveAPP

struct PIPNoticePaginationTests {
    private let longText = String(repeating: "長訊息換行測試。", count: 30)

    @Test func shortTextStaysOnOnePage() {
        let pages = PIPNoticePagination.pages("短提示", canvasWidth: 300, showAvatar: false)
        #expect(pages == ["短提示"])
    }

    @Test func longTextIsCappedAtFourPagesWithEllipsis() {
        let pages = PIPNoticePagination.pages(longText, canvasWidth: 300, showAvatar: false)
        #expect(pages.count == PIPNoticePagination.maxPages)
        #expect(pages.last?.hasSuffix("…") == true)

        let width = PIPNoticePagination.textWidth(
            canvasWidth: 300, showAvatar: false, pageCount: pages.count)
        let font = UIFont.systemFont(ofSize: PIPNoticePagination.fontSize)
        for page in pages {
            let measured = (page as NSString).size(withAttributes: [.font: font]).width
            #expect(measured <= width + 0.5)
        }
    }

    @Test func avatarReducesAvailableWidthAndCanAddPages() {
        let without = PIPNoticePagination.pages(longText, canvasWidth: 300, showAvatar: false)
        let with = PIPNoticePagination.pages(longText, canvasWidth: 300, showAvatar: true)
        #expect(with.count >= without.count)
        #expect(PIPNoticePagination.textWidth(canvasWidth: 300, showAvatar: true, pageCount: 1)
                < PIPNoticePagination.textWidth(canvasWidth: 300, showAvatar: false, pageCount: 1))
    }

    @Test func multiplePagesReserveDotSpace() {
        let one = PIPNoticePagination.textWidth(canvasWidth: 300, showAvatar: false, pageCount: 1)
        let many = PIPNoticePagination.textWidth(canvasWidth: 300, showAvatar: false, pageCount: 2)
        #expect(many < one)
    }

    @Test func emptyTextHasNoPages() {
        #expect(PIPNoticePagination.pages("", canvasWidth: 300, showAvatar: false).isEmpty)
    }
}
