import Testing
import Foundation
import CryptoKit
@testable import EdmundCore

// End-to-end Mermaid tests. Opt-in so they never run in CI or on a machine
// without the payload; each skips (passing with no assertions) when the env
// var is unset.
//
//   MERMAID_ARCHIVE=<path to beautiful-mermaid-<v>.tar.gz>
//     Exercises installer-unpack → JSCore-load → SVG-render against a local
//     payload, without shipping the ~500 KB artifact into the repo.
//     Build one with scripts/build-mermaid-payload.sh.
@Suite("Mermaid — JS integration (gated on MERMAID_ARCHIVE)")
struct MermaidJSIntegrationTests {

    private var archiveURL: URL? {
        ProcessInfo.processInfo.environment["MERMAID_ARCHIVE"].map { URL(fileURLWithPath: $0) }
    }
    private func sha256(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }
    private var style: MermaidStyle {
        MermaidStyle(backgroundHex: "#FFFFFF", foregroundHex: "#27272A")
    }

    /// Unpacks the payload into a temp dir and returns a loaded, enabled renderer.
    @MainActor
    private func loadedRenderer(into dir: URL) async throws -> MermaidRenderer {
        let data = try Data(contentsOf: #require(archiveURL))
        let installer = ExtensionPayloadInstaller(payload: MermaidRelease.payload)
        try await installer.installAtomically(archive: data, sha256: sha256(data), into: dir)

        let renderer = MermaidRenderer()
        renderer.load(dir: dir)
        renderer.isEnabled = true
        return renderer
    }

    @Test("Unpack, load, and render every supported diagram type")
    @MainActor func endToEnd() async throws {
        guard archiveURL != nil else { return }   // skipped without the local payload
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mermaid-it-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let renderer = try await loadedRenderer(into: dir)

        #expect(renderer.isReady)

        // The payload redistributes third-party work — beautiful-mermaid (MIT),
        // elkjs (EPL-2.0) and entities (BSD-2) — so the license text has to
        // travel inside the archive that lands on disk, not just live in the
        // hosting repo. EPL-2.0 in particular requires it.
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("beautiful-mermaid.js").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("licenses/LICENSE-beautiful-mermaid").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("licenses/LICENSE-elkjs").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("licenses/LICENSE-entities").path))

        // The six types the extension's description claims.
        let diagrams: [(String, String)] = [
            ("flowchart", "graph TD\n  A[Write] --> B[Preview]\n  B --> C{Export?}\n  C -->|PDF| D[Print]"),
            ("state", "stateDiagram-v2\n  [*] --> Idle\n  Idle --> Running: start\n  Running --> [*]"),
            ("sequence", "sequenceDiagram\n  Alice->>Bob: Hello\n  Bob-->>Alice: Hi"),
            ("class", "classDiagram\n  class Doc { +String title\n +save() }\n  Doc <|-- Markdown"),
            ("er", "erDiagram\n  DOC ||--o{ BLOCK : contains"),
            ("xychart", "xychart-beta\n  title \"Sales\"\n  x-axis [jan, feb, mar]\n  y-axis \"Rev\" 0 --> 100\n  bar [30, 60, 90]\n  line [30, 60, 90]"),
        ]
        for (name, source) in diagrams {
            let svg = renderer.svg(source: source, style: style)
            #expect(svg != nil, "\(name) should render")
            #expect(svg?.hasPrefix("<svg") == true, "\(name) should be an SVG")
        }
    }

    @Test("Rendered SVG is self-contained: no webfont import, no script, arrowheads intact")
    @MainActor func selfContained() async throws {
        guard archiveURL != nil else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mermaid-it-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let renderer = try await loadedRenderer(into: dir)

        let svg = try #require(renderer.svg(source: "graph TD\n  A[Write] --> B[Preview]", style: style))

        // Read mode's page reaches the network for nothing. The payload shim
        // strips the Google Fonts @import; this asserts it actually did.
        #expect(!svg.contains("@import"))
        #expect(!svg.contains("fonts.googleapis.com"))
        #expect(!svg.contains("<script"))

        // Colour custom properties and color-mix() are deliberately KEPT —
        // WebKit resolves both, and the <svg> tag carries --bg/--fg inline, so
        // the result is still self-contained. Flattening them in JS would only
        // matter for a CoreSVG raster path, which read mode doesn't use.
        #expect(svg.contains("--bg:#FFFFFF"))
        #expect(svg.contains("var(--"))

        // Labels and arrowheads are the whole point of a diagram.
        #expect(svg.contains("Write"))
        #expect(svg.contains("Preview"))
        #expect(svg.contains("<marker"))
        #expect(svg.contains("url(#arrowhead)"))
    }

    @Test("Malformed diagram source returns nil rather than throwing")
    @MainActor func malformedSource() async throws {
        guard archiveURL != nil else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mermaid-it-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let renderer = try await loadedRenderer(into: dir)

        #expect(renderer.svg(source: "not a diagram at all {{{", style: style) == nil)
        #expect(renderer.svg(source: "", style: style) == nil)

        // A disabled extension refuses to render even with the payload loaded,
        // so toggling it off takes effect without an uninstall.
        renderer.isEnabled = false
        #expect(renderer.svg(source: "graph TD\n  A --> B", style: style) == nil)
    }

    @Test("Repeat renders are served from cache and stay identical")
    @MainActor func cacheHits() async throws {
        guard archiveURL != nil else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mermaid-it-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let renderer = try await loadedRenderer(into: dir)

        let source = "graph TD\n  A[One] --> B[Two]"
        let first = try #require(renderer.svg(source: source, style: style))
        let second = try #require(renderer.svg(source: source, style: style))
        #expect(first == second)

        // A different palette is a different cache entry, not a stale hit.
        let dark = MermaidStyle(backgroundHex: "#292929", foregroundHex: "#DDDDDD")
        let darkSVG = try #require(renderer.svg(source: source, style: dark))
        #expect(darkSVG.contains("--bg:#292929"))
        #expect(darkSVG != first)
    }

    // Exercises the pinned coordinates themselves — downloads
    // `MermaidRelease.archiveURL`, checks it against `archiveSHA256`, installs,
    // and renders. This is the only test that can catch a payload that was
    // never uploaded, a moved/renamed release asset, or a hash pinned from a
    // local build that doesn't match the hosted file. Opt-in via `MERMAID_LIVE`
    // because it needs the network and writes to the real Application Support
    // install directory, so it must not run in CI or on an offline machine.
    // Mirrors `RaTeXWasmIntegrationTests.pinnedReleaseInstalls`.
    @Test("Pinned release URL and SHA-256 install and render for real")
    @MainActor func pinnedReleaseInstalls() async throws {
        guard ProcessInfo.processInfo.environment["MERMAID_LIVE"] != nil else { return }

        let renderer = MermaidRenderer()
        renderer.isEnabled = true
        await renderer.install()
        #expect(renderer.isReady, "install failed — check the pinned URL and SHA-256")

        let svg = try #require(renderer.svg(source: "graph TD\n  A[One] --> B[Two]", style: style))
        #expect(svg.hasPrefix("<svg"))
        // The labels prove the JS actually laid the diagram out, rather than a
        // stub or an error string that happens to start with "<svg".
        #expect(svg.contains("One"))
        #expect(svg.contains("Two"))
    }
}
