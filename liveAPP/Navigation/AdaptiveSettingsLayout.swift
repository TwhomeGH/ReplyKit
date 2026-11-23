import SwiftUI

/// 共用設計值，單位為 point；不是 Apple 裝置規格。width 必須是扣除外層邊距後的可用寬度。
enum SettingsCardLayoutPolicy {
    static let pagePadding: CGFloat = 16
    static let spacing: CGFloat = 16
    static let maximumContentWidth: CGFloat = 1280
    static let minimumCardWidth: CGFloat = 420

    /// 放得下兩張可讀卡片才切雙欄；輔助使用字體保留單欄。
    static func columnCount(availableWidth: CGFloat, minimumWidth: CGFloat,
                            accessibility: Bool) -> Int {
        guard availableWidth.isFinite, minimumWidth.isFinite,
              minimumWidth > 0, !accessibility else { return 1 }
        return min(max(0, availableWidth), maximumContentWidth) >= minimumWidth * 2 + spacing ? 2 : 1
    }
}

/// 設定與診斷共用的卡片網格；依視窗寬度而非裝置種類決定欄數。
/// 輔助使用字體維持單欄，避免分割視窗或放大文字時擠壓控制項。
struct AdaptiveSettingsGrid<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var minimumCardWidth = SettingsCardLayoutPolicy.minimumCardWidth
    let width: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        let count = SettingsCardLayoutPolicy.columnCount(availableWidth: width,
            minimumWidth: minimumCardWidth, accessibility: dynamicTypeSize.isAccessibilitySize)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: SettingsCardLayoutPolicy.spacing, alignment: .top), count: count),
                  alignment: .leading, spacing: SettingsCardLayoutPolicy.spacing) {
            content()
        }
        .frame(maxWidth: SettingsCardLayoutPolicy.maximumContentWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// 將原本 List 的區段轉為可並排的卡片；內容仍由原資料擁有者提供。
struct SettingsDashboardCard<Header: View, Content: View>: View {
    private let header: Header
    private let content: Content

    init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.header = header()
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            // 診斷卡片以內容決定高度；窄欄與大字體時換行，不壓成省略號。
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
        } label: {
            header
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension SettingsDashboardCard where Header == Text {
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(header: { Text(title) }, content: content)
    }
}

/// 兩欄各自依內容高度排列，共用外層捲動；切換寬度時保留子視圖身分。
struct AdaptiveSettingsColumns<Leading: View, Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var minimumCardWidth = SettingsCardLayoutPolicy.minimumCardWidth
    let width: CGFloat
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        let count = SettingsCardLayoutPolicy.columnCount(availableWidth: width,
            minimumWidth: minimumCardWidth, accessibility: dynamicTypeSize.isAccessibilitySize)
        let layout = count == 2
            ? AnyLayout(HStackLayout(alignment: .top, spacing: SettingsCardLayoutPolicy.spacing))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: SettingsCardLayoutPolicy.spacing))
        layout {
            VStack(alignment: .leading, spacing: SettingsCardLayoutPolicy.spacing) { leading() }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: SettingsCardLayoutPolicy.spacing) { trailing() }
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: SettingsCardLayoutPolicy.maximumContentWidth)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}
