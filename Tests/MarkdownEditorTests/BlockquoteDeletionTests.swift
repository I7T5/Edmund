import Testing
import AppKit
@testable import MarkdownEditorCore

/// Regression: characters in a callout / block quote must stay deletable.
///
/// Each rendered block becomes one NSTextBlock ("table cell"), and NSTextView
/// refuses `deleteBackward` at the boundary between two adjacent cells. When
/// block-quote lines were split per line, deleting toward a line end silently
/// did nothing. Merging a quote's lines into one block (one cell) fixes it —
/// this test runs the real, laid-out delete path in a window to catch it.
@Suite("Block-quote / callout deletion")
struct BlockquoteDeletionTests {

    @MainActor private func windowed() -> EditorTextView {
        let e = makeEditor()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: win.contentLayoutRect)
        scroll.documentView = e
        win.contentView = scroll
        win.makeFirstResponder(e)
        return e
    }

    @Test("Deleting through a multi-line callout's header keeps working")
    @MainActor func deleteThroughCalloutHeader() {
        let e = windowed()
        e.loadContent("> [!note]\n> hi\n> there")
        e.setSelectedRange(NSRange(location: 9, length: 0))   // end of "> [!note]"
        e.recompose(cursorInRaw: 9)
        e.layoutManager?.ensureLayout(for: e.textContainer!)

        // Delete the whole "[!note]" marker, one char at a time.
        for _ in 0..<7 {
            let before = e.rawSource
            e.deleteBackward(nil)
            e.layoutManager?.ensureLayout(for: e.textContainer!)
            #expect(e.rawSource != before)   // every press must remove a character
        }
        #expect(e.rawSource == "> \n> hi\n> there")
    }

    @Test("Deleting at a plain multi-line quote's internal line end works")
    @MainActor func deleteAtQuoteLineEnd() {
        let e = windowed()
        e.loadContent("> aaa\n> bbb")
        e.setSelectedRange(NSRange(location: 5, length: 0))   // end of "> aaa"
        e.recompose(cursorInRaw: 5)
        e.layoutManager?.ensureLayout(for: e.textContainer!)
        let before = e.rawSource
        e.deleteBackward(nil)
        #expect(e.rawSource != before)
        #expect(e.rawSource == "> aa\n> bbb")
    }
}
