import UIKit

/// 次要提示的單行分頁；純計算，runtime 與測試共用。
enum PIPNoticePagination {
    static let maxPages = 4
    static let fontSize: CGFloat = 12

    /// 依畫布寬度切成最多四頁；超過時最後一頁截斷加省略號。
    static func pages(_ text: String, canvasWidth: CGFloat, showAvatar: Bool) -> [String] {
        guard !text.isEmpty else { return [] }
        let font = UIFont.systemFont(ofSize: fontSize)
        func measured(_ value: String) -> CGFloat {
            (value as NSString).size(withAttributes: [.font: font]).width
        }
        func split(_ width: CGFloat) -> [String] {
            var pages: [String] = []
            var current = ""
            var currentWidth: CGFloat = 0
            for character in text {
                let value = String(character)
                let characterWidth = measured(value)
                if currentWidth + characterWidth > width, !current.isEmpty {
                    pages.append(current)
                    current = value
                    currentWidth = characterWidth
                } else {
                    current += value
                    currentWidth += characterWidth
                }
            }
            if !current.isEmpty { pages.append(current) }
            return pages
        }

        let avatarInset = showAvatar
            ? (PIPOverlayLayout.noticeAvatarSize + PIPOverlayLayout.noticeAvatarGap)
            : 0
        let baseWidth = max(1, canvasWidth
            - PIPOverlayLayout.contentLeading
            - PIPOverlayLayout.contentTrailing
            - avatarInset)
        var pageWidth = baseWidth
        var result = split(pageWidth)
        if result.count > 1 {
            pageWidth = max(1, baseWidth - PIPOverlayLayout.noticePageDotsReserve - 6)
            result = split(pageWidth)
        }
        guard result.count > maxPages else { return result }

        var limited = Array(result.prefix(maxPages))
        var last = limited[maxPages - 1]
        let ellipsis = "…"
        let ellipsisWidth = measured(ellipsis)
        while !last.isEmpty && measured(last) + ellipsisWidth > pageWidth {
            last.removeLast()
        }
        limited[maxPages - 1] = last + ellipsis
        return limited
    }

    /// 每一頁可用文字寬度；測試與除錯用。
    static func textWidth(canvasWidth: CGFloat, showAvatar: Bool, pageCount: Int) -> CGFloat {
        let avatarInset = showAvatar
            ? (PIPOverlayLayout.noticeAvatarSize + PIPOverlayLayout.noticeAvatarGap)
            : 0
        let base = canvasWidth
            - PIPOverlayLayout.contentLeading
            - PIPOverlayLayout.contentTrailing
            - avatarInset
        guard pageCount > 1 else { return max(1, base) }
        return max(1, base - PIPOverlayLayout.noticePageDotsReserve - 6)
    }
}
