// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Edmund",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.7.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "EdmundCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "SwiftMath", package: "SwiftMath"),
            ]),
        // The user-facing app is "Edmund" (CFBundleName); the executable target —
        // and so the Mach-O binary at Edmund.app/Contents/MacOS/edmd — is "edmd",
        // an expansion of "Editor for Markdown". A quiet backronym for anyone who
        // peeks inside the bundle or runs `swift run edmd`.
        .executableTarget(
            name: "edmd",
            dependencies: ["EdmundCore", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(
            name: "EdmundTests",
            dependencies: ["EdmundCore"]),
    ]
)
