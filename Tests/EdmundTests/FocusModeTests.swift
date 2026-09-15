import Testing
import AppKit
@testable import EdmundCore

// Focus mode's decision half: which laid-out fragments fade. The fade itself
// (one transparency layer over the fragment's whole draw) is verified on screen.
@Suite("Focus mode")
@MainActor
struct FocusModeTests {

    /// Whether each source line's fragment would be dimmed, in document order.
    /// Reads the live layout, so it exercises the same path the draw does.
    private func dimmed(_ editor: EditorTextView) -> [Bool] {
        guard let tlm = editor.textLayoutManager else { return [] }
        var flags: [Bool] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location,
                                         options: [.ensuresLayout]) { fragment in
            // A plain fragment has no draw to dim in, so focus mode must never
            // leave one behind while it is on.
            flags.append((fragment as? DecoratedTextLayoutFragment)?.dimmedByFocus ?? false)
            return true
        }
        return flags
    }

    /// An editor with focus mode already on — it has to be set before layout,
    /// since the delegate reads it when it vends each fragment.
    private func focusedEditor(_ content: String) -> EditorTextView {
        let editor = makeEditor()
        editor.focusMode = true
        editor.loadContent(content)
        return editor
    }

    @Test("Focus mode is off by default")
    func defaultsOff() {
        let editor = makeEditor()
        #expect(!editor.focusMode)
        editor.loadContent("alpha\nbeta\n")
        #expect(dimmed(editor).allSatisfy { !$0 })
    }

    @Test("Only the caret's line escapes the dim")
    func caretLine() {
        let editor = focusedEditor("alpha\nbeta\ngamma\n")
        editor.setSelectedRange(NSRange(location: 7, length: 0))   // inside "beta"
        #expect(dimmed(editor) == [true, false, true])
    }

    @Test("Every line the selection touches escapes the dim")
    func selectionSpan() {
        let editor = focusedEditor("alpha\nbeta\ngamma\ndelta\n")
        // From inside "alpha" through inside "gamma".
        editor.setSelectedRange(NSRange(location: 2, length: 12))
        #expect(dimmed(editor) == [false, false, false, true])
    }

    @Test("A selection ending at a line start doesn't claim that line")
    func selectionStopsAtLineStart() {
        let editor = focusedEditor("alpha\nbeta\ngamma\n")
        editor.setSelectedRange(NSRange(location: 0, length: 6))   // "alpha\n" exactly
        #expect(dimmed(editor) == [false, true, true])
    }

    @Test("The caret at the end of a document with no trailing newline")
    func caretAtDocumentEnd() {
        // There is no line whose range *contains* this location — it is every
        // range's exclusive end — so the last line has to claim it.
        let editor = focusedEditor("alpha\nbeta")
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        #expect(dimmed(editor) == [true, false])
    }

    @Test("A caret at a line start focuses that line, not the one above")
    func caretAtLineStart() {
        let editor = focusedEditor("alpha\nbeta\n")
        editor.setSelectedRange(NSRange(location: 6, length: 0))   // "b" of beta
        #expect(dimmed(editor) == [true, false])
    }

    @Test("Turning focus mode off dims nothing")
    func turnedOff() {
        let editor = focusedEditor("alpha\nbeta\ngamma\n")
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        #expect(dimmed(editor).contains(true))
        // No re-vend, no restyle — the fragments are the same objects; they
        // just stop dimming, which is what the Settings toggle relies on.
        editor.focusMode = false
        #expect(dimmed(editor).allSatisfy { !$0 })
    }
}
