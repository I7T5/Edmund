import Testing
import Foundation
import CryptoKit
import AppKit
@testable import EdmundCore

// `.serialized`: a couple of tests manipulate the shared real install
// directory (`RaTeXInstaller.installDirectory`); running them in parallel
// races (one removes the dir while another writes into it).
@Suite("RaTeX — scaffold", .serialized)
struct RaTeXScaffoldTests {

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // `.black`/`.labelColor` are catalog colors without RGB components — the
    // render cache key needs `.redComponent` etc., so callers always resolve
    // to device RGB first (see EditorTextView.mathOverlay); mirror that here.
    private var testColor: NSColor { NSColor(red: 0, green: 0, blue: 0, alpha: 1) }

    // A deliberate tripwire: RaTeXRelease.archiveSHA256 is a real, hosted pin
    // (see the type's doc comment) — this just checks it looks like a SHA-256
    // rather than an accidental placeholder/typo. It deliberately does NOT
    // hardcode the hash value here (that'd just duplicate the source of truth);
    // the real hash is exercised for real by RaTeXWasmIntegrationTests (gated
    // on RATEX_ARCHIVE, since it's a live network fetch).
    @Test("A real archive hash is pinned")
    func releaseIsConfigured() {
        #expect(RaTeXRelease.isConfigured)
        #expect(RaTeXRelease.archiveSHA256.count == 64)
        #expect(RaTeXRelease.archiveSHA256 == RaTeXRelease.archiveSHA256.lowercased())
        #expect(RaTeXRelease.archiveSHA256.allSatisfy { $0.isHexDigit })
    }

    @Test("Hash verify accepts a matching digest and rejects a mismatch")
    func hashVerification() async throws {
        let installer = RaTeXInstaller()
        let data = Data("hello ratex".utf8)

        await #expect(throws: RaTeXInstallError.hashMismatch) {
            try await installer.verify(data, sha256: "0000000000000000000000000000000000000000000000000000000000000000")
        }
        try await installer.verify(data, sha256: sha256Hex(data))   // does not throw
    }

    @Test("Atomic install unpacks the archive and stamps it for re-verification")
    func atomicInstallRoundTrips() async throws {
        // Build a tiny tar.gz with the expected layout using the system tar.
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("ratex-stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging.appendingPathComponent("fonts"), withIntermediateDirectories: true)
        try Data("fake wasm".utf8).write(to: staging.appendingPathComponent("ratex_wasm_bg.wasm"))
        try Data("fake glue".utf8).write(to: staging.appendingPathComponent("ratex_wasm.js"))
        try Data("fake font".utf8).write(to: staging.appendingPathComponent("fonts/KaTeX_Main-Regular.ttf"))
        defer { try? fm.removeItem(at: staging) }
        let tarball = fm.temporaryDirectory.appendingPathComponent("ratex-\(UUID().uuidString).tar.gz")
        defer { try? fm.removeItem(at: tarball) }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = staging
        tar.arguments = ["-czf", tarball.path, "ratex_wasm_bg.wasm", "ratex_wasm.js", "fonts"]
        try tar.run(); tar.waitUntilExit()
        let archive = try Data(contentsOf: tarball)

        let installer = RaTeXInstaller()
        let dir = fm.temporaryDirectory.appendingPathComponent("ratex-inst-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }

        try await installer.installAtomically(archive: archive, sha256: sha256Hex(archive), into: dir)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("ratex_wasm_bg.wasm").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("ratex_wasm.js").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("fonts/KaTeX_Main-Regular.ttf").path))
        // Stamp records the archive hash so a relaunch skips re-download.
        let stamp = try String(contentsOf: dir.appendingPathComponent(".verified-sha256"), encoding: .utf8)
        #expect(stamp == sha256Hex(archive))
    }

    @Test("Uninstall removes the version directory and resets state")
    func uninstallRemovesInstallDirectory() async throws {
        let installer = RaTeXInstaller()
        let dir = RaTeXInstaller.installDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: dir.appendingPathComponent("ratex_wasm_bg.wasm"))

        await installer.uninstall()

        #expect(!FileManager.default.fileExists(atPath: dir.path))
        let state = await installer.state
        #expect(state == .notInstalled)
    }

    @Test("Uninstall is safe to call when nothing was ever installed")
    func uninstallWithoutInstallDoesNotThrow() async {
        let installer = RaTeXInstaller()
        try? FileManager.default.removeItem(at: RaTeXInstaller.installDirectory)   // ensure absent
        await installer.uninstall()   // must not crash
        let state = await installer.state
        #expect(state == .notInstalled)
    }

    @Test("RaTeXRenderer is not ready and never crashes before installing")
    @MainActor func rendererNotReadyBeforeInstall() {
        let renderer = RaTeXRenderer()
        #expect(!renderer.isReady)
        #expect(renderer.render(latex: "x^2", displayMode: false,
                                pointSize: 16, color: testColor) == nil)
    }

    @Test("Coordinator falls back to SwiftMath when RaTeX isn't ready")
    @MainActor func coordinatorFallsBackWhenRaTeXNotReady() {
        let coord = MathRendering.shared
        coord.alternate = RaTeXRenderer()
        defer { coord.alternate = nil }
        #expect(coord.active === coord.swiftMath)   // not ready → default wins
        let result = coord.render(latex: "x^2", displayMode: false,
                                  pointSize: 16, color: testColor)
        #expect(result != nil)   // still renders, via SwiftMath
    }

    @Test("RaTeXRenderer.uninstall is safe to call before ever installing")
    @MainActor func rendererUninstallWithoutInstall() async {
        let renderer = RaTeXRenderer()
        await renderer.uninstall()   // must not crash
        #expect(!renderer.isReady)
    }

    @Test("AdvancedMathExtension.uninstall delegates to its renderer")
    @MainActor func advancedMathUninstallDelegates() async {
        let ext = AdvancedMathExtension.shared
        await ext.uninstall()   // must not crash
        #expect(!ext.isInstalled)
    }
}
