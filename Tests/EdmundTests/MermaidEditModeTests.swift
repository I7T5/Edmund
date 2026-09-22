import Testing
import AppKit
import CryptoKit
@testable import EdmundCore

@Suite("Mermaid — edit mode")
struct MermaidEditModeTests {

    private let fence = "```mermaid\ngraph TD\n  A[Write] --> B[Preview]\n```"

    // MARK: Fallback — the extension off / not installed (ungated)

    @Test("With no renderer, an inactive mermaid fence is styled as an ordinary code block")
    @MainActor func fallbackIsAPlainCodeBlock() {
        MermaidRenderer.shared.isEnabled = false
        let editor = makeEditor()
        let styled = editor.styleBlock(fence)

        // Nothing is drawn over it, its source is visible, and it carries the
        // code box — exactly what a ```swift fence gets.
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) == nil)
        #expect(!isHidden(at: 11, in: styled))     // "graph TD" is on line 2
        #expect(styled.attribute(.blockDecoration, at: 0, effectiveRange: nil) != nil)
        let label = styled.attribute(.codeBlockLabel, at: 0, effectiveRange: nil) as? String
        #expect(label == "Mermaid")
    }

    @Test("Read mode reserves the same margin around a diagram as Edit mode")
    @MainActor func marginsMatchReadMode() {
        let editor = makeEditor()
        let css = HTMLTheme.css(.default, callouts: [:], dark: false)
        // Both are one line of the code face. Asserted as the rendered CSS
        // rather than by re-deriving the metric, so a change to either side
        // that silently parts them fails here.
        #expect(css.contains("--diagram-margin: \(Int(editor.mermaidDiagramMargin))px"))
        #expect(css.contains(".mermaid-diagram { margin: var(--diagram-margin) 0;"))
    }

    // MARK: Rendered (gated on a real payload)

    private var archiveURL: URL? {
        ProcessInfo.processInfo.environment["MERMAID_ARCHIVE"].map { URL(fileURLWithPath: $0) }
    }

    /// Stands up `MermaidRenderer.shared` from the local payload — the editor
    /// reaches the shared instance directly — and tears it down after.
    @MainActor
    private func withLoadedRenderer(_ body: () throws -> Void) async throws {
        guard let archiveURL else { return }   // skipped without the local payload
        let data = try Data(contentsOf: archiveURL)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mermaid-em-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            MermaidRenderer.shared.unload()
            MermaidRenderer.shared.isEnabled = false
        }
        let installer = ExtensionPayloadInstaller(payload: MermaidRelease.payload)
        try await installer.installAtomically(archive: data, sha256: sha, into: dir)
        MermaidRenderer.shared.load(dir: dir)
        MermaidRenderer.shared.isEnabled = true
        try body()
    }

    @Test("Caret outside: the fence collapses under a diagram overlay on its first character")
    @MainActor func inactiveRendersDiagram() async throws {
        try await withLoadedRenderer {
            let editor = makeEditor()
            let styled = editor.styleBlock(fence)

            let overlay = styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) as? FragmentOverlay
            let image = try #require(overlay?.image)
            #expect(image.size.width > 0 && image.size.height > 0)
            // Everything after the anchor is hidden: rest of the opening fence,
            // the source, the closing fence.
            #expect(isHidden(at: 1, in: styled))
            #expect(isHidden(at: 11, in: styled))
            #expect(isHidden(at: (fence as NSString).length - 1, in: styled))
            // The picture hangs below the anchor's baseline, and the anchor
            // line keeps an ordinary code-line height — that is what keeps the
            // caret and the line number the size and place they'd be on any
            // other line (a line box as tall as the diagram takes both with it).
            #expect(overlay?.bounds.minY == -(overlay?.bounds.height ?? 0))
            let ps = try #require(styled.attribute(.paragraphStyle, at: 0,
                                                   effectiveRange: nil) as? NSParagraphStyle)
            let normalLine = NSLayoutManager().defaultLineHeight(for: editor.codeBlockFont)
            #expect(ps.minimumLineHeight == normalLine)
            #expect(ps.minimumLineHeight < image.size.height)

            // Its height is reserved as fragment padding instead, so the space
            // is clickable and the next block tiles clear of it.
            let deco = try #require(styled.attribute(.blockDecoration, at: 0,
                                                     effectiveRange: nil) as? BlockDecoration)
            guard case .box(let background, _, let edges, let borderWidth, let bottomPad) = deco.kind
            else { Issue.record("expected a box decoration"); return }
            #expect(background == .clear)            // it paints nothing
            #expect(edges.isEmpty)
            #expect(borderWidth == 0)

            // Even margins: TextKit puts the baseline of a line box sized by
            // minimumLineHeight on its bottom edge, and the picture hangs from
            // that baseline — so the anchor line *is* the gap above it, and the
            // padding left below the picture has to be the same to match.
            #expect(bottomPad - image.size.height == ps.minimumLineHeight)
        }
    }

    @Test("Caret inside: raw source and the ordinary dimmed fences, no overlay")
    @MainActor func activeShowsSource() async throws {
        try await withLoadedRenderer {
            let editor = makeEditor()
            let styled = editor.styleBlock(fence, cursorPosition: 14)
            #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) == nil)
            #expect(!isHidden(at: 11, in: styled))
        }
    }

    @Test("Source that doesn't parse falls back to the code block rather than a broken overlay")
    @MainActor func malformedFallsBack() async throws {
        try await withLoadedRenderer {
            let editor = makeEditor()
            let styled = editor.styleBlock("```mermaid\nnot a diagram {{{\n```")
            #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) == nil)
            #expect(styled.attribute(.blockDecoration, at: 0, effectiveRange: nil) != nil)
        }
    }

    @Test("Disabling the extension reverts to the code block without an unload")
    @MainActor func disableReverts() async throws {
        try await withLoadedRenderer {
            let editor = makeEditor()
            #expect(editor.styleBlock(fence).attribute(.fragmentOverlay, at: 0, effectiveRange: nil) != nil)
            MermaidRenderer.shared.isEnabled = false
            #expect(editor.styleBlock(fence).attribute(.fragmentOverlay, at: 0, effectiveRange: nil) == nil)
        }
    }
}
