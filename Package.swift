// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Edmund",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.7.0"),
        .package(url: "https://github.com/lukilabs/beautiful-mermaid-swift", from: "1.0.4"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Keep BeautifulMermaid's API behind a module boundary. It publishes
        // broad AppKit extensions (including NSColor.init(hex:)); the bridge
        // keeps those implementation details out of EdmundCore source.
        .target(
            name: "EdmundMermaidBridge",
            dependencies: [
                .product(name: "BeautifulMermaid", package: "beautiful-mermaid-swift"),
            ]),
        .target(
            name: "EdmundCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "SwiftMath", package: "SwiftMath"),
                "EdmundMermaidBridge",
            ],
            resources: [.copy("Resources/Syntaxes")]),
        // The user-facing app is "Edmund" (CFBundleName); the executable target —
        // and so the Mach-O binary at Edmund.app/Contents/MacOS/edmd — is "edmd",
        // an expansion of "Editor for Markdown". A quiet backronym for anyone who
        // peeks inside the bundle or runs `swift run edmd`.
        .executableTarget(
            name: "edmd",
            dependencies: ["EdmundCore", .product(name: "Sparkle", package: "Sparkle")]),
        // The Quick Look preview extension. Built as an executable target but
        // packaged as an `.appex` by build-app.sh; its entry point is
        // Foundation's NSExtensionMain, redirected via the linker `-e` flag
        // (SwiftPM has no first-class app-extension product type).
        .executableTarget(
            name: "EdmundQuickLook",
            dependencies: ["EdmundCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]),
        .testTarget(
            name: "EdmundTests",
            dependencies: ["EdmundCore", "edmd"]),
    ]
)
