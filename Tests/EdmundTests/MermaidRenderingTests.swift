import AppKit
import Testing
@testable import EdmundCore

@Suite("Mermaid — native rendering", .serialized)
@MainActor
struct MermaidRenderingTests {
    private let markdown = """
        ```mermaid
        graph TD
          A[Write] --> B[Preview]
        ```
        """

    private func preparePreview(for editor: EditorTextView) async -> String? {
        guard let span = SyntaxHighlighter.parse(markdown).first(where: {
            if case .codeBlock = $0.kind { return true }
            return false
        }) else { return nil }
        let source = (markdown as NSString).substring(with: span.contentRange)
        let style = MermaidRenderStyle(editorTheme: editor.theme, dark: false)
        guard await MermaidImageStore.shared.prepare(source: source, style: style) != nil
        else { return nil }
        return source
    }

    @Test("Info-string recognition is case-insensitive and uses its first word")
    func languageRecognition() {
        #expect(MermaidSyntax.matches(language: "mermaid"))
        #expect(MermaidSyntax.matches(language: "MERMAID title=Example"))
        #expect(!MermaidSyntax.matches(language: "swift"))
        #expect(!MermaidSyntax.matches(language: nil))
    }

    @Test("HTML renderer emits an asset placeholder only while Mermaid is enabled")
    func htmlFeatureGate() {
        let on = HTMLRenderer.render(markdown: markdown)
        #expect(on.contains(
            "<div id=\"edmund-l1\" class=\"mermaid-diagram\" data-source=\""))
        #expect(!on.contains("<code class=\"language-mermaid\">"))

        let options = ReadRenderOptions(
            features: MarkdownFeatures.all.subtracting(.mermaid))
        let off = HTMLRenderer.render(markdown: markdown, options: options)
        #expect(!off.contains("data-source="))
        #expect(off.contains("<code class=\"language-mermaid\">"))
    }

    @Test("Read/PDF document contains safe inline SVG and preserves its source anchor")
    func documentSVG() {
        let html = DocumentHTML.full(
            markdown: markdown,
            theme: .default,
            callouts: Callout.defaultStyles,
            dark: false
        )
        #expect(!html.contains("data-source="))
        #expect(html.contains(
            "<div id=\"edmund-l1\" class=\"mermaid-diagram\" role=\"img\""))
        #expect(html.contains("<svg xmlns=\"http://www.w3.org/2000/svg\""))
        #expect(html.contains(".mermaid-diagram svg"))
        #expect(html.contains("background: var(--code-bg)"))
        #expect(html.contains("border: 1px solid var(--table-border)"))
        #expect(html.contains("fill=\"var(--_node-fill)\""))
        #expect(!html.contains(#/fill="#[0-9A-Fa-f]{6} [0-9]+%/#))
        #expect(!html.contains(#/stroke="#[0-9A-Fa-f]{6} [0-9]+%/#))
        #expect(!html.lowercased().contains("<script"))
    }

    @Test("An unsupported diagram falls back to escaped source code")
    func unsupportedFallback() {
        let source = """
            ```mermaid
            this is not a diagram
            ```
            """
        let html = DocumentHTML.full(
            markdown: source,
            theme: .default,
            callouts: Callout.defaultStyles,
            dark: false
        )
        #expect(!html.contains("data-source="))
        #expect(html.contains("<code class=\"language-mermaid\">"))
        #expect(html.contains("this is not a diagram"))
    }

    @Test("Inactive editor fence draws a native overlay without changing its string")
    func editorOverlay() async {
        let editor = makeEditor()
        let span = SyntaxHighlighter.parse(markdown).first {
            if case .codeBlock = $0.kind { return true }
            return false
        }
        #expect(span != nil)
        guard let span else { return }
        let source = (markdown as NSString).substring(with: span.contentRange)
        #expect(await preparePreview(for: editor) == source)

        let styled = editor.styleBlock(markdown)
        #expect(styled.string == markdown)
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil)
                is FragmentOverlay)
        guard let decoration = blockDecoration(at: 0, in: styled),
              case .box(_, let border, let edges, let width, _) = decoration.kind else {
            Issue.record("Mermaid preview has no frame")
            return
        }
        #expect(border != nil)
        #expect(edges == .all)
        #expect(width == 1)
    }

    @Test("Active editor fence remains editable raw source")
    func activeEditorSource() async {
        let editor = makeEditor()
        #expect(await preparePreview(for: editor) != nil)
        let styled = editor.styleBlock(markdown, cursorPosition: 20)
        #expect(styled.string == markdown)
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) == nil)
        let body = (markdown as NSString).range(of: "graph TD")
        let font = styled.attribute(.font, at: body.location, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == editor.codeBlockFont.pointSize)
        #expect(blockDecoration(at: 0, in: styled) != nil)
        #expect(blockDecoration(at: styled.length - 1, in: styled) != nil)
    }

    @Test("Preview and editable source keep the same framed height")
    func stableEditorHeight() async {
        let editor = makeEditor()
        #expect(await preparePreview(for: editor) != nil)
        let document = "lead paragraph\n\n\(markdown)\n\nREFERENCE LINE\n"
        editor.loadContent(document)
        ensureFullLayout(editor)

        let ns = document as NSString
        let lead = ns.range(of: "lead paragraph").location
        let source = ns.range(of: "graph TD").location
        let reference = ns.range(of: "REFERENCE LINE").location

        editor.setSelectedRange(NSRange(location: lead, length: 0))
        editor.recomposeIncremental(cursorInRaw: lead)
        ensureFullLayout(editor)
        let renderedY = editor.lineRect(forCharacterAt: reference)?.minY

        editor.setSelectedRange(NSRange(location: source, length: 0))
        editor.recomposeIncremental(cursorInRaw: source)
        ensureFullLayout(editor)
        let activeY = editor.lineRect(forCharacterAt: reference)?.minY

        #expect(renderedY != nil)
        #expect(activeY != nil)
        if let renderedY, let activeY {
            #expect(abs(activeY - renderedY) < 1,
                    "Mermaid frame shifted by \(activeY - renderedY)pt")
        }
        #expect(editor.rawSource == editor.string)
    }
}
