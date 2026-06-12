import Testing
import AppKit
@testable import MarkdownEditorCore

/// Lazy rendering: in a scroll view, loads style only the viewport window
/// synchronously; the idle drain and scroll promotion converge the rest.
/// (Headless editors — no scroll view — style everything synchronously, which
/// is what every other suite exercises.)
@Suite("Lazy rendering")
struct LazyRenderingTests {

    @MainActor private func windowedEditor(height: CGFloat = 300) -> (EditorTextView, NSScrollView) {
        let editor = makeEditor()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: height),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: win.contentLayoutRect)
        scroll.documentView = editor
        win.contentView = scroll
        win.makeFirstResponder(editor)
        editor.typewriterModeEnabled = false
        editor.isVerticallyResizable = true
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        return (editor, scroll)
    }

    @MainActor private func bigDocument() -> String {
        (0..<800).map { "paragraph **number** \($0)" }.joined(separator: "\n\n")
    }

    @Test("Load styles the viewport window; far blocks stay base-attributed")
    @MainActor func loadIsViewportFirst() {
        let (editor, _) = windowedEditor()
        editor.loadContent(bigDocument())

        #expect(editor.blocks.first?.isStyled == true)
        let last = editor.blocks.count - 1
        #expect(editor.blocks[last].isStyled == false)

        // An unstyled block's characters carry exactly the base attributes:
        // the bold delimiters are not yet hidden.
        let lastLoc = editor.blocks[last].range.location
        let f = font(at: lastLoc, in: editor)
        #expect(f?.fontName == editor.bodyFont.fontName)
        #expect((f?.pointSize ?? 0) >= 1.0)
        assertMatchesFullRecomposeOracle(editor, "viewport-first load")
    }

    @Test("The idle drain converges the whole document to the oracle")
    @MainActor func drainConverges() {
        let (editor, _) = windowedEditor()
        editor.loadContent(bigDocument())
        drainAllStyling(editor)
        #expect(editor.blocks.allSatisfy { $0.isStyled })
        assertMatchesFullRecomposeOracle(editor, "after drain")
    }

    @Test("Scrolling promotes newly visible blocks synchronously")
    @MainActor func scrollPromotes() {
        let (editor, scroll) = windowedEditor()
        editor.loadContent(bigDocument())
        ensureFullLayout(editor)
        editor.sizeToFit()
        editor.layoutSubtreeIfNeeded()

        let last = editor.blocks.count - 1
        #expect(editor.blocks[last].isStyled == false)

        // Jump to the bottom of the document.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, editor.frame.height - 300)))
        scroll.reflectScrolledClipView(scroll.contentView)

        #expect(editor.blocks[last].isStyled == true,
                "scroll promotion must style blocks entering the viewport")
    }

    @Test("Clicking into an unstyled block styles it as the active block")
    @MainActor func clickIntoUnstyled() {
        let (editor, _) = windowedEditor()
        editor.loadContent(bigDocument())

        let last = editor.blocks.count - 1
        #expect(editor.blocks[last].isStyled == false)
        let target = editor.blocks[last].range.location + 2
        editor.setSelectedRange(NSRange(location: target, length: 0))
        editor.recomposeIncremental(cursorInRaw: target)

        #expect(editor.blocks[last].isStyled == true)
        #expect(editor.activeBlockIndex == last)
        assertMatchesFullRecomposeOracle(editor, "after activating unstyled block")
    }

    @Test("Undo mid-drain converges cleanly")
    @MainActor func undoMidDrain() {
        let (editor, _) = windowedEditor()
        editor.loadContent(bigDocument())
        // One edit so there's an undo snapshot, then undo before draining.
        type("x", into: editor)
        editor.performUndo()
        drainAllStyling(editor)
        #expect(editor.blocks.allSatisfy { $0.isStyled })
        #expect(editor.rawSource == bigDocument())
        assertMatchesFullRecomposeOracle(editor, "after undo + drain")
    }
}
