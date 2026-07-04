import Testing
import AppKit
@testable import EdmundCore

/// Delete drift round 6 (issue #156, 2026-07-03 22:13 log): a bypassed
/// deletion (drag-move whose drop lands nowhere) skips TextKit 2's selection
/// fixup along with didChangeText. The queued fixup then fires at the next
/// `endEditing` — the heal's attribute-only restyle — via
/// `_fixSelectionAfterChangeInCharacterRange`, mapping the stale selection
/// against post-edit coordinates and leaping the caret (~two wrapped lines
/// forward in the field report). The heal must both collapse the selection to
/// the edit point before syncing and re-assert it after, because the late
/// fixer moves even a freshly set valid caret.
@Suite("Bypassed-edit caret repair (delete drift round 6)")
struct WrappedParagraphCaretTests {

    @MainActor private func windowedEditor() -> EditorTextView {
        let editor = makeEditor()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: win.contentLayoutRect)
        scroll.documentView = editor
        win.contentView = scroll
        win.makeFirstResponder(editor)
        editor.typewriterModeEnabled = false
        editor.isVerticallyResizable = true
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        return editor
    }

    private static let hodgePoster = """
    # Hodgerank

    ## Introduction
    Everyone has heard about Calculus. However, not nearly as much people \
    will have its counterpart - discrete calculus, also known as graph theory.

    Nowadays, discrete calculus is widely used in various applied sciences. \
    One of its potential uses is ranking. See Sizemore, Strang et al., and Xu et al.

    Here, we apply Hodgerank to college admissions data
    """

    /// Bypassed deletion mid wrapped paragraph: after the heal, the caret must
    /// sit at the deletion point — not wherever TextKit 2's late selection
    /// fixup drops it (321 for 290 in the live repro).
    @Test @MainActor func healPlacesCaretAtBypassedDeletionPoint() {
        let editor = windowedEditor()
        editor.loadContent(Self.hodgePoster)
        let dragged = (editor.rawSource as NSString).range(of: "Sizemore, ")
        editor.setSelectedRange(dragged)

        // The drag-move bypass: shouldChangeText + mutation, no didChangeText.
        #expect(editor.shouldChangeText(in: dragged, replacementString: ""))
        editor.textStorage!.replaceCharacters(in: dragged, with: "")

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(editor.textStorage!.string == editor.rawSource)
        #expect(editor.selectedRange() == NSRange(location: dragged.location, length: 0),
                "caret must be at the deletion point after the heal")

        // Follow-up edits stay put: backspace deletes exactly one char at the
        // caret, then typing inserts at the caret.
        editor.deleteBackward(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(editor.selectedRange() == NSRange(location: dragged.location - 1, length: 0),
                "caret leaped on the first post-heal backspace")
        editor.deleteBackward(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(editor.selectedRange() == NSRange(location: dragged.location - 2, length: 0),
                "caret leaped on the second post-heal backspace")
        #expect(editor.textStorage!.string == editor.rawSource)
    }
}
