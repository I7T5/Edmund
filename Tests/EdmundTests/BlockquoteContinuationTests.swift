import Testing
import AppKit
@testable import EdmundCore

@Suite("EditorTextView — Block-quote / Callout Continuation")
struct BlockquoteContinuationTests {

    @Test("Enter at the end of a callout body line continues with '> '")
    @MainActor func continueCalloutBody() {
        let editor = makeEditor()
        editor.loadContent("> [!note]\n> body")
        editor.setSelectedRange(NSRange(location: (editor.rawSource as NSString).length, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == "> [!note]\n> body\n> ")
    }

    @Test("Enter after the callout header continues with '> '")
    @MainActor func continueCalloutHeader() {
        let editor = makeEditor()
        editor.loadContent("> [!note]")
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == "> [!note]\n> ")
    }

    @Test("Enter on an empty quote line breaks out of the callout")
    @MainActor func breakOutOnEmpty() {
        let editor = makeEditor()
        editor.loadContent("> [!note]\n> ")
        editor.setSelectedRange(NSRange(location: 12, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == "> [!note]\n")
    }

    @Test("Plain block quotes continue too")
    @MainActor func continuePlainQuote() {
        let editor = makeEditor()
        editor.loadContent("> quote")
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == "> quote\n> ")
    }

    @Test("Non-quote lines get a normal newline")
    @MainActor func normalNewline() {
        let editor = makeEditor()
        editor.loadContent("hello")
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == "hello\n")
    }

    @Test("Indented quote keeps its indentation")
    @MainActor func indentedQuote() {
        let editor = makeEditor()
        editor.loadContent("  > note")
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == "  > note\n  > ")
    }

    @Test("A nested callout line continues at its depth ('> > ')")
    @MainActor func continueNestedCallout() {
        let editor = makeEditor()
        editor.loadContent("> [!note] Note\n> > tip body")
        editor.setSelectedRange(NSRange(location: (editor.rawSource as NSString).length, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == "> [!note] Note\n> > tip body\n> > ")
    }

    @Test("A nested plain quote line continues at its depth ('> > ')")
    @MainActor func continueNestedQuote() {
        let editor = makeEditor()
        editor.loadContent("> outer\n> > inner")
        editor.setSelectedRange(NSRange(location: (editor.rawSource as NSString).length, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == "> outer\n> > inner\n> > ")
    }

    @Test("Enter on an empty nested line steps out one level")
    @MainActor func stepOutOneLevel() {
        let editor = makeEditor()
        editor.loadContent("> [!note]\n> > body\n> > ")
        editor.setSelectedRange(NSRange(location: (editor.rawSource as NSString).length, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == "> [!note]\n> > body\n> ")
    }

    @Test("reduceQuotePrefix drops the deepest level")
    @MainActor func reduceQuotePrefix() {
        #expect(EditorTextView.reduceQuotePrefix("> > ") == "> ")
        #expect(EditorTextView.reduceQuotePrefix("> ") == "")
        #expect(EditorTextView.reduceQuotePrefix("  > > ") == "  > ")
        #expect(EditorTextView.reduceQuotePrefix("  > ") == "  ")
    }
}
