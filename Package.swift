// swift-tools-version:5.9
// 此 Package.swift 僅供 SourceKit-LSP 索引使用（語法檢查／函數跳轉）
// 無法在 Windows/Linux 上實際編譯（需 Apple SDK）
import PackageDescription

let package = Package(
    name: "ReplyKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/TwhomeGH/HaishinKitFixSwfit.git", branch: "main")
    ],
    targets: [
        .target(
            name: "liveAPP",
            dependencies: [],
            path: "liveAPP",
            exclude: [
                "Config.xcconfig",
                "liveAPP.entitlements",
                "Info.plist",
                "Assets.xcassets"
            ]
        ),
        .target(
            name: "ReplyKIT",
            dependencies: [
                .product(name: "HaishinKit", package: "HaishinKit"),
                .product(name: "RTMPHaishinKit", package: "HaishinKit")
            ],
            path: "ReplyKIT",
            exclude: ["Info.plist"]
        ),
        .target(
            name: "ReplyKITSetupUI",
            dependencies: [],
            path: "ReplyKITSetupUI",
            exclude: ["Info.plist"]
        ),
        .target(
            name: "ReplyKITNotification",
            dependencies: [],
            path: "ReplyKITNotification",
            exclude: ["Info.plist"]
        )
    ]
)
