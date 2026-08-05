// swift-tools-version:5.9
// 此 Package.swift 僅供 SourceKit-LSP 索引使用（語法檢查／函數跳轉）
// 無法在 Windows/Linux 上實際編譯（需 Apple SDK）
//
// 用本地 stub（Packages/HaishinKit）而非真 fork：真 fork 大量 import
// CoreMedia/CoreVideo/UIKit 等 Apple-only module，在 Windows SDK 不存在，
// 每次編輯都會觸發 index build 失敗並讓擴展跳去 sourcekit-lsp 輸出。
// stub 只 import Foundation，可在 Windows 編出 module，函數跳轉仍可用。
//
// liveAPP 刻意不放在此 package：它大量 import SwiftUI/ReplayKit/UIKit，
// 這些 module 在 Windows SDK 不存在，每次編輯都會觸發 index build 失敗並
// 讓擴展跳去 sourcekit-lsp 輸出。移出後 liveAPP 檔案改走 fallback build
// system（單檔語法檢查），不再嘗試建 module。
import PackageDescription

let package = Package(
    name: "ReplyKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "Packages/HaishinKit")
    ],
    targets: [
        .target(
            name: "ReplyKIT",
            dependencies: [
                .product(name: "HaishinKit", package: "HaishinKit"),
                .product(name: "RTMPHaishinKit", package: "HaishinKit")
            ],
            path: "ReplyKIT",
            exclude: ["Info.plist"]
        )
    ]
)
