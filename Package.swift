// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "md",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.7.0"),
    ],
    targets: [
        .target(
            name: "MarkdownEditorCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "SwiftMath", package: "SwiftMath"),
            ]),
        .executableTarget(
            name: "md",
            dependencies: ["MarkdownEditorCore"]),
        .testTarget(
            name: "MarkdownEditorTests",
            dependencies: ["MarkdownEditorCore"]),
    ]
)
