import Testing
import Foundation
import CryptoKit
import AppKit
@testable import EdmundCore

// End-to-end RaTeX wasm tests. Both are opt-in so neither runs in CI or on an
// offline machine; each skips (passing with no assertions) when its env var is
// unset.
//
//   RATEX_ARCHIVE=<path to ratex-wasm-<v>.tar.gz>
//     Exercises installer-unpack → JSCore-host → DisplayList-render against a
//     local payload, without shipping the 1 MB artifact into the repo.
//   RATEX_LIVE=1
//     Exercises the pinned release coordinates by downloading them for real.
@Suite("RaTeX — wasm integration (gated on RATEX_ARCHIVE / RATEX_LIVE)")
struct RaTeXWasmIntegrationTests {

    private var archiveURL: URL? {
        ProcessInfo.processInfo.environment["RATEX_ARCHIVE"].map { URL(fileURLWithPath: $0) }
    }
    private func sha256(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }
    private var black: NSColor { NSColor(red: 0, green: 0, blue: 0, alpha: 1) }

    @Test("Unpack, load, and render inline + display math with real metrics")
    @MainActor func endToEnd() async throws {
        guard let archiveURL else { return }   // skipped without the local payload
        let data = try Data(contentsOf: archiveURL)

        let installer = RaTeXInstaller()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ratex-it-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await installer.installAtomically(archive: data, sha256: sha256(data), into: dir)

        // Files unpacked to the expected layout.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ratex_wasm_bg.wasm").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ratex_wasm.js").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("fonts/KaTeX_Math-Italic.ttf").path))
        // The payload redistributes MIT-licensed third-party work, so the
        // license text has to travel inside the archive that lands on disk —
        // not just live in the hosting repo.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("licenses/LICENSE-RaTeX").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("licenses/LICENSE-KaTeX-fonts").path))

        let host = WasmMathHost()
        host.load(dir: dir)
        #expect(host.isLoaded)

        // Inline `x^2`: renders, positive size, ascent+descent == image height.
        let inline = host.render(latex: "x^2", displayMode: false, pointSize: 16, color: black)
        #expect(inline != nil)
        if let m = inline {
            #expect(m.image.size.width > 0 && m.image.size.height > 0)
            #expect(abs((m.ascent + m.descent) - m.image.size.height) < 0.01)
        }

        // Display environment that SwiftMath handles differently — must render.
        let display = host.render(latex: "\\begin{aligned} a&=1 \\\\ b&=2 \\end{aligned}",
                                  displayMode: true, pointSize: 18, color: black)
        #expect(display != nil)

        // Garbage LaTeX returns nil (→ per-equation fallback to SwiftMath).
        let bad = host.render(latex: "\\frac{", displayMode: false, pointSize: 16, color: black)
        #expect(bad == nil)

        // `displayMode` actually reaches RaTeX. Before 0.1.14 the argument
        // didn't exist and the call defaulted to display, so inline math came
        // back display-typeset: `\sum`'s limits stacked above and below it
        // instead of sitting beside it. That shows up as a much taller, much
        // narrower image — so the two modes must not agree here.
        let sum = "\\sum_{i=1}^{n} i"
        let sumInline = host.render(latex: sum, displayMode: false, pointSize: 16, color: black)
        let sumDisplay = host.render(latex: sum, displayMode: true, pointSize: 16, color: black)
        #expect(sumInline != nil)
        #expect(sumDisplay != nil)
        if let i = sumInline, let d = sumDisplay {
            #expect(d.image.size.height > i.image.size.height * 1.5)
            #expect(d.image.size.width < i.image.size.width)
        }

        // `aligned` expands its row spacing to fit tall rows. The 0.1.12 defect
        // (docs/investigations/math-ratex-multirow-investigation.md) inverted
        // this: three rows of `\lim`/`\frac`/`\exp` reported a *smaller* total
        // height than three rows of bare letters, because the row pitch never
        // grew past the plain-letter case — which is what collapsed the rows
        // on top of each other in read mode and overlapped the next paragraph
        // in edit mode. Comparing the two shapes, rather than pinning an
        // absolute height, keeps this honest across future RaTeX versions.
        let simpleRows = host.render(latex: "\\begin{aligned} a &= b \\\\ c &= d \\\\ e &= f \\end{aligned}",
                                     displayMode: true, pointSize: 16, color: black)
        let tallRows = host.render(latex: """
            \\begin{aligned}
            \\lim_{n\\to\\infty} \\frac{a_n}{b_n} &= \\exp\\left(\\frac{1}{2}\\right) \\\\
            \\lim_{n\\to\\infty} \\frac{c_n}{d_n} &= \\exp\\left(\\frac{3}{4}\\right) \\\\
            \\lim_{n\\to\\infty} \\frac{e_n}{f_n} &= \\exp\\left(\\frac{5}{6}\\right)
            \\end{aligned}
            """, displayMode: true, pointSize: 16, color: black)
        #expect(simpleRows != nil)
        #expect(tallRows != nil)
        if let simple = simpleRows, let tall = tallRows {
            #expect(tall.image.size.height > simple.image.size.height)
        }

        // Unload clears readiness.
        host.unload()
        #expect(!host.isLoaded)
    }

    // Exercises the pinned coordinates themselves — downloads
    // `RaTeXRelease.archiveURL`, checks it against `archiveSHA256`, installs,
    // and renders. This is the only test that can catch a payload that was
    // never uploaded, a moved/renamed release asset, or a hash pinned from a
    // local build that doesn't match the hosted file. Opt-in via `RATEX_LIVE`
    // because it needs the network and writes to the real Application Support
    // install directory, so it must not run in CI or on an offline machine.
    @Test("Pinned release URL and SHA-256 install and render for real")
    @MainActor func pinnedReleaseInstalls() async throws {
        guard ProcessInfo.processInfo.environment["RATEX_LIVE"] != nil else { return }

        let renderer = RaTeXRenderer()
        await renderer.install()
        #expect(renderer.isReady, "install failed — check the pinned URL and SHA-256")

        // Inline and display must disagree, the same property the offline test
        // pins, but here through the artifact users actually download.
        let sum = "\\sum_{i=1}^{n} i"
        let inline = renderer.render(latex: sum, displayMode: false, pointSize: 16, color: black)
        let display = renderer.render(latex: sum, displayMode: true, pointSize: 16, color: black)
        #expect(inline != nil)
        #expect(display != nil)
        if let i = inline, let d = display {
            #expect(d.image.size.height > i.image.size.height * 1.5)
        }
    }
}
