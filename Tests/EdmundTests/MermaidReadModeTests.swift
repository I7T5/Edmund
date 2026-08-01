import Testing
import Foundation
import CryptoKit
@testable import EdmundCore

@Suite("Mermaid — read mode and export")
struct MermaidReadModeTests {

    private let markdown = """
    # Doc

    ```mermaid
    graph TD
      A[Write] --> B[Preview]
    ```

    Tail paragraph.
    """

    // MARK: Placeholder emission (no renderer involved)

    @Test("A mermaid fence is wrapped in a placeholder carrying its source")
    func placeholderEmitted() {
        let html = HTMLRenderer.render(markdown: markdown)
        #expect(html.contains("class=\"mermaid-diagram\""))
        #expect(html.contains("data-source=\""))

        // The source rides base64-encoded so no markdown punctuation can break
        // out of the attribute.
        let source = "graph TD\n  A[Write] --> B[Preview]"
        #expect(html.contains(Data(source.utf8).base64EncodedString()))
    }

    @Test("A non-mermaid fence is left completely alone")
    func otherLanguagesUntouched() {
        let html = HTMLRenderer.render(markdown: "```swift\nlet x = 1\n```")
        #expect(!html.contains("mermaid-diagram"))
        #expect(html.contains("code-block-wrap"))
    }

    // MARK: Fallback — the extension off / not installed

    @Test("With no renderer, a mermaid fence renders as an ordinary code block")
    @MainActor func fallbackIsAPlainCodeBlock() {
        MermaidRenderer.shared.isEnabled = false

        let full = DocumentHTML.full(markdown: markdown, theme: .default,
                                     callouts: [:], dark: false)
        // No placeholder leaks into the finished document…
        #expect(!full.contains("data-source="))
        // …and what's left is a real code block, copy button and all, so the
        // fallback can't drift from how every other fence renders.
        // Matched as an element: ".code-block-wrap" also appears in the
        // stylesheet, so a bare substring check could never fail.
        #expect(full.contains("class=\"code-block-wrap\">"))
        // The code is syntax-highlighted into spans, so the fence body is only
        // contiguous a token at a time.
        #expect(full.contains("Preview"))
        // NOT `!contains("<svg")` — the copy button's icon is an inline SVG on
        // every code block. An arrowhead marker ref is mermaid-only.
        #expect(!full.contains("url(#arrowhead)"))
    }

    @Test("The unwrapped fallback keeps the block's source-line anchor")
    @MainActor func fallbackKeepsScrollAnchor() {
        MermaidRenderer.shared.isEnabled = false

        let full = DocumentHTML.full(markdown: markdown, theme: .default,
                                     callouts: [:], dark: false)
        // The fence starts on line 3. Losing this id would punch a hole in
        // Read mode's scroll-sync anchor list exactly where the diagram is.
        #expect(full.contains("<div id=\"edmund-l3\" class=\"code-block-wrap\""))
    }

    // MARK: Rendered output (gated on a real payload)

    private var archiveURL: URL? {
        ProcessInfo.processInfo.environment["MERMAID_ARCHIVE"].map { URL(fileURLWithPath: $0) }
    }

    @MainActor
    private func withLoadedRenderer(_ body: (URL) async throws -> Void) async throws {
        guard let archiveURL else { return }   // skipped without the local payload
        let data = try Data(contentsOf: archiveURL)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mermaid-rm-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            MermaidRenderer.shared.unload()
            MermaidRenderer.shared.isEnabled = false
        }
        let installer = ExtensionPayloadInstaller(payload: MermaidRelease.payload)
        try await installer.installAtomically(archive: data, sha256: sha, into: dir)

        // DocumentHTML reaches the shared instance directly, so the test has to
        // stand that one up rather than inject its own.
        MermaidRenderer.shared.load(dir: dir)
        MermaidRenderer.shared.isEnabled = true
        try await body(dir)
    }

    @Test("An installed, enabled extension inlines the diagram as SVG")
    @MainActor func rendersInlineSVG() async throws {
        try await withLoadedRenderer { _ in
            let full = DocumentHTML.full(markdown: markdown, theme: .default,
                                         callouts: [:], dark: false)

            #expect(full.contains("<svg"))
            #expect(full.contains("Write"))
            #expect(full.contains("url(#arrowhead)"))
            // The placeholder is consumed and the code-block fallback is gone.
            #expect(!full.contains("data-source="))
            #expect(!full.contains("class=\"code-block-wrap\">"))
            // Read mode's page reaches the network for nothing and runs no
            // script — the CSP meta is belt-and-braces, this is the check that
            // nothing needing them got inlined.
            #expect(!full.contains("@import"))
            #expect(!full.contains("fonts.googleapis.com"))

            // Screen readers get the diagram source, not the SVG's text nodes
            // read out in layout order.
            #expect(full.contains("role=\"img\""))
            #expect(full.contains("aria-label=\"graph TD"))

            // The source-line anchor survives the fill pass.
            #expect(full.contains("<div id=\"edmund-l3\" class=\"mermaid-diagram\""))
        }
    }

    @Test("The diagram picks up the page palette for the target appearance")
    @MainActor func followsAppearance() async throws {
        try await withLoadedRenderer { _ in
            let light = DocumentHTML.full(markdown: markdown, theme: .default,
                                          callouts: [:], dark: false)
            let dark = DocumentHTML.full(markdown: markdown, theme: .default,
                                         callouts: [:], dark: true)
            #expect(light != dark)
            // Resolved against the requested appearance rather than the current
            // one, because an export can target either.
            let lightBG = HTMLTheme.backgroundColor(dark: false).hexString
            let darkBG = HTMLTheme.backgroundColor(dark: true).hexString
            #expect(light.contains("--bg:\(lightBG)"))
            #expect(dark.contains("--bg:\(darkBG)"))
        }
    }

    @Test("A diagram that doesn't parse falls back to the code block")
    @MainActor func malformedFallsBack() async throws {
        try await withLoadedRenderer { _ in
            let bad = """
            ```mermaid
            not a diagram at all {{{
            ```
            """
            let full = DocumentHTML.full(markdown: bad, theme: .default,
                                         callouts: [:], dark: false)
            #expect(!full.contains("url(#arrowhead)"))
            #expect(full.contains("class=\"code-block-wrap\">"))
            #expect(full.contains("a diagram at all"))
        }
    }
}
