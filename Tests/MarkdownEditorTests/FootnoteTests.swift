import Testing
import AppKit
@testable import MarkdownEditorCore

@Suite("Footnotes")
struct FootnoteTests {

    private func refIDs(_ text: String) -> [String] {
        SyntaxHighlighter.parse(text).compactMap {
            if case .footnoteReference(let id) = $0.kind { return id }; return nil
        }
    }
    private func defIDs(_ text: String) -> [String] {
        SyntaxHighlighter.parse(text).compactMap {
            if case .footnoteDefinition(let id) = $0.kind { return id }; return nil
        }
    }

    @Test("Inline [^id] parses as a footnote reference")
    func referenceParses() {
        #expect(refIDs("a statement[^1] and[^note] here") == ["1", "note"])
    }

    @Test("[^id]: at block start parses as a definition, not a reference")
    func definitionParses() {
        let text = "[^1]: the definition text"
        #expect(defIDs(text) == ["1"])
        #expect(refIDs(text).isEmpty)
    }

    @Test("[^id] inside a code span is not a footnote")
    func codeSpanNotFootnote() {
        #expect(refIDs("inline `[^1]` code").isEmpty)
    }

    @Test("Rendered reference is superscripted (raised, shrunk)")
    @MainActor func referenceSuperscript() {
        let editor = makeEditor()
        let text = "see[^1] here"
        let styled = editor.styleBlock(text, cursorPosition: nil)
        let idLoc = (text as NSString).range(of: "1").location
        let offset = styled.attribute(.baselineOffset, at: idLoc, effectiveRange: nil) as? CGFloat
        #expect((offset ?? 0) > 0)
        let f = styled.attribute(.font, at: idLoc, effectiveRange: nil) as? NSFont
        #expect((f?.pointSize ?? 99) < editor.bodyFont.pointSize)
    }

    @Test("Definition marker is dimmed; the text stays normal")
    @MainActor func definitionDimmed() {
        let editor = makeEditor()
        let text = "[^1]: body text"
        let styled = editor.styleBlock(text, cursorPosition: nil)
        // The "[" of the marker is dimmed.
        let markerColor = styled.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(markerColor == editor.syntaxDimColor)
        // The body text after the marker keeps the normal foreground.
        let bodyLoc = (text as NSString).range(of: "body").location
        let bodyColor = styled.attribute(.foregroundColor, at: bodyLoc, effectiveRange: nil) as? NSColor
        #expect(bodyColor != editor.syntaxDimColor)
    }
}
