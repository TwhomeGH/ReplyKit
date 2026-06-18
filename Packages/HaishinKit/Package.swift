// swift-tools-version:5.9
// 本套件是 HaishinKit.swift 的樁（stub），僅供 SourceKit-LSP 索引用。
// 實際推流需在 macOS 上透過 Xcode + 真實 HaishinKit 套件編譯。
import PackageDescription

let package = Package(
    name: "HaishinKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "HaishinKit", targets: ["HaishinKit"]),
        .library(name: "RTMPHaishinKit", targets: ["RTMPHaishinKit"])
    ],
    targets: [
        .target(name: "HaishinKit", path: "Sources/HaishinKit"),
        .target(name: "RTMPHaishinKit", dependencies: ["HaishinKit"], path: "Sources/RTMPHaishinKit")
    ]
)
