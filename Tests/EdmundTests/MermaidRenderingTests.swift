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
        let style = MermaidRenderStyle(editorTheme: editor.theme, dark: false)
        #expect(await MermaidImageStore.shared.prepare(source: source, style: style) != nil)

        let styled = editor.styleBlock(markdown)
        #expect(styled.string == markdown)
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil)
                is FragmentOverlay)
    }

    @Test("Active editor fence remains editable raw source")
    func activeEditorSource() async {
        let editor = makeEditor()
        let styled = editor.styleBlock(markdown, cursorPosition: 20)
        #expect(styled.string == markdown)
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) == nil)
        let body = (markdown as NSString).range(of: "graph TD")
        let font = styled.attribute(.font, at: body.location, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == editor.codeBlockFont.pointSize)
    }
}
