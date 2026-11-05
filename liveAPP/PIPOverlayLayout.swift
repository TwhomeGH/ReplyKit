import Foundation

/// PiP 疊加層的安全區與列位置；座標以 `300x200` 設計畫布為基準。
///
/// 系統 PiP 的關閉鈕與返回 App 鈕由系統繪製，沒有公開 API 可隱藏、停用或搬動，
/// 因此把它們佔用的上緣與左右角落視為固定保留區，內容一律避開。
enum PIPOverlayLayout {
    /// 系統 PiP 按鈕直徑與邊距；兩顆按鈕都落在上方保留帶內。
    static let controlDiameter: CGFloat = 44
    static let controlMargin: CGFloat = 6
    /// 上方系統控制列保留高度；兩顆按鈕都落在此帶內。
    static var controlBandHeight: CGFloat { controlDiameter + controlMargin * 2 }
    /// 控制帶內左右按鈕的保留寬度（按鈕＋邊距）。
    static var sideInset: CGFloat { controlDiameter + controlMargin * 2 }
    /// 保留帶以外的內容左緣。
    static let contentLeading: CGFloat = 12
    static let contentTrailing: CGFloat = 12
    /// 狀態列（計時／直播／觀眾）留在控制帶的左右空檔內。
    static let statusRowY: CGFloat = 20
    /// 控制帶以下的列，統一使用 `contentLeading` 左緣。
    static let nowTimeY: CGFloat = 60
    static let noticeY: CGFloat = 84
    static let noticeLineHeight: CGFloat = 20
    /// 聊天室安全頂距；300x200 時為 104。
    static let minimumChatTopMargin: CGFloat = 104

    static func statusRowAvailableWidth(canvasWidth: CGFloat) -> CGFloat {
        max(0, canvasWidth - sideInset * 2)
    }

    static func chatTopMargin(canvasHeight: CGFloat) -> CGFloat {
        max(minimumChatTopMargin, canvasHeight * 0.26)
    }

    /// 狀態列在系統按鈕之間的取捨：優先保留計時與狀態，其次觀眾數，最後才顯示時鐘圖示。
    static func statusRowPlan(availableWidth: CGFloat,
                              iconWidth: CGFloat,
                              elapsedWidth: CGFloat,
                              statusWidth: CGFloat,
                              viewerWidth: CGFloat) -> StatusRowPlan {
        var plan = StatusRowPlan(drawIcon: true, drawViewer: viewerWidth > 0, usedWidth: 0)

        func width(drawIcon: Bool, drawViewer: Bool) -> CGFloat {
            var total = elapsedWidth
            if drawIcon { total += iconWidth + 4 }
            if statusWidth > 0 { total += 8 + statusWidth }
            if drawViewer, viewerWidth > 0 {
                total += (statusWidth > 0 ? 6 : 8) + viewerWidth
            }
            return total
        }

        if width(drawIcon: true, drawViewer: plan.drawViewer) <= availableWidth {
            plan.usedWidth = width(drawIcon: true, drawViewer: plan.drawViewer)
            return plan
        }

        plan.drawIcon = false
        if width(drawIcon: false, drawViewer: plan.drawViewer) <= availableWidth {
            plan.usedWidth = width(drawIcon: false, drawViewer: plan.drawViewer)
            return plan
        }

        plan.drawViewer = false
        plan.usedWidth = width(drawIcon: false, drawViewer: false)
        return plan
    }
}

/// `statusRowPlan` 的結果；`usedWidth` 不含左側安全邊距。
struct StatusRowPlan: Equatable {
    var drawIcon: Bool
    var drawViewer: Bool
    var usedWidth: CGFloat
}
