import SwiftUI

/// 設定與診斷共用的卡片網格；依視窗寬度而非裝置種類決定欄數。
/// 輔助使用字體維持單欄，避免分割視窗或放大文字時擠壓控制項。
struct AdaptiveSettingsGrid<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let width: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        let count = width >= 900 && !dynamicTypeSize.isAccessibilitySize ? 2 : 1
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: count),
                  alignment: .leading, spacing: 16) {
            content()
        }
        .frame(maxWidth: 1280, alignment: .leading)
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
        } label: {
            header
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
    let width: CGFloat
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        let layout = width >= 900 && !dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        layout {
            VStack(alignment: .leading, spacing: 16) { leading() }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 16) { trailing() }
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: 1280)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}
