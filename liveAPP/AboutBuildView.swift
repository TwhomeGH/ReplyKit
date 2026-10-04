import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct AboutBuildView: View {
    private let info = BuildInformation.current
    @State private var copied = false
    var body: some View {
        List {
            Section {
                Text("以原始碼 commit 辨識此產物，不依賴 App 版本號或 Build Version。")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(info.rows.indices, id: \.self) { index in
                    let row = info.rows[index]
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.0).font(.caption).foregroundStyle(.secondary)
                        Text(row.0.contains("commit") && row.1 != "未知" ? String(row.1.prefix(12)) : row.1)
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            Section {
                Button(copied ? "已複製完整資訊" : "複製完整版本資訊") {
                    #if os(iOS)
                    UIPasteboard.general.string = info.report
                    #elseif os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.report, forType: .string)
                    #endif
                    copied = true
                }
                ShareLink("分享版本資訊", item: info.report)
                Text("複製與分享包含完整 commit。未知代表建置時沒有取得該項資料；鎖定值未核對時，不代表已確認實際套件來源。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("關於與建置資訊")
    }
}
