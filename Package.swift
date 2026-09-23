// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The Mac App Store variant must not link Sparkle (App Review rejects a
// second updater). build-app.sh --variant mas sets EDMUND_MAS=1; the package
// dependency stays declared either way so Package.resolved never churns —
// only the edmd target stops linking the product, and the updater code in
// main.swift compiles out via `#if canImport(Sparkle)`.
let linksSparkle = ProcessInfo.processInfo.environment["EDMUND_MAS"] == nil

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
            ],
            resources: [.copy("Resources/Syntaxes"), .copy("Resources/Themes")]),
        // The user-facing app is "Edmund" (CFBundleName); the executable target —
        // and so the Mach-O binary at Edmund.app/Contents/MacOS/edmd — is "edmd",
        // an expansion of "Editor for Markdown". A quiet backronym for anyone who
        // peeks inside the bundle or runs `swift run edmd`.
        .executableTarget(
            name: "edmd",
            dependencies: ["EdmundCore"]
                + (linksSparkle ? [.product(name: "Sparkle", package: "Sparkle")] : [])),
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
