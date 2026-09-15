import Testing
import AppKit
@testable import EdmundCore

/// The `</>` button and the row pill share one strip of margin. Both have to be
/// reachable while a cell is being edited — the button is how a table goes back
/// to raw markdown, and the hit test only considers a button that is revealed.

@Suite("Table raw button slot")
@MainActor
struct TableRawButtonSlotTests {

    private let doc = "Intro.\n\n| c1 | c2 |\n| --- | --- |\n| a | b |\n| c | d |\n"

    private func loadEditor(_ text: String) -> EditorTextView {
        let editor = makeEditor()
        editor.updateContentInset()
        editor.loadContent(text)
        ensureFullLayout(editor)
        layOutViewport(editor)
        return editor
    }

    private func caret(_ editor: EditorTextView, to needle: String) {
        let offset = (editor.rawSource as NSString).range(of: needle).location
        editor.setSelectedRange(NSRange(location: offset, length: 0))
        if let block = editor.blockIndexForRawOffset(offset) {
            editor.restyleBlock(block, cursorInBlock: offset - editor.blocks[block].range.location)
        }
        ensureFullLayout(editor)
        layOutViewport(editor)
    }

    @Test("Editing a cell keeps the button on screen and clickable")
    func buttonSurvivesCellEditing() {
        let editor = loadEditor(doc)
        caret(editor, to: "a")
        guard let table = editor.blocks.firstIndex(where: { $0.kind == .table }) else {
            Issue.record("no table")
            return
        }
        #expect(editor.tableRawButtonIsRevealed(blockIndex: table))
        let revealed = editor.revealedTableRawButtons()
        #expect(revealed.contains { $0.blockIndex == table })
    }

    /// The pill follows the caret, so on the header row it lands in the strip
    /// the button uses. Neither may cover the other: whichever you aim at is
    /// the one you must get.
    @Test("The button and the row pill never overlap")
    func buttonAndPillDoNotOverlap() {
        let editor = loadEditor(doc)
        for cell in ["c1", "a", "c"] {
            caret(editor, to: cell)
            let buttons = editor.revealedTableRawButtons()
            #expect(!buttons.isEmpty, "no button with the caret in \(cell)")
            for button in buttons {
                for handle in editor.tableHandles() where handle.axis == .row {
                    #expect(!button.rect.intersects(handle.rect),
                            "button and row pill overlap with the caret in \(cell)")
                }
            }
        }
    }

    /// The pill sits on the caret's row, so it reaches the button's line only
    /// while the header row is the active one. Every other row leaves the slot
    /// free, and the button belongs back in it.
    @Test("The button returns to the line number's slot off the header row")
    func buttonReturnsToItsSlot() {
        let editor = loadEditor(doc)
        // The slot itself, measured with the caret on a row whose pill is
        // nowhere near it, rather than recomputed from the same geometry the
        // code uses — that would only assert the arithmetic against itself.
        caret(editor, to: "| a")
        guard let free = editor.visibleTableRawButtons().first else {
            Issue.record("no button")
            return
        }

        caret(editor, to: "c1")   // the header row: the pill is in the way
        guard let shifted = editor.visibleTableRawButtons().first else {
            Issue.record("no button on the header row")
            return
        }
        #expect(shifted.rect.minX < free.rect.minX - 1)

        for cell in ["| a", "| c |"] { // any other row: the slot is free again
            caret(editor, to: cell)
            guard let button = editor.visibleTableRawButtons().first else {
                Issue.record("no button with the caret in \(cell)")
                return
            }
            #expect(abs(button.rect.minX - free.rect.minX) < 0.5,
                    "the button stayed out of its slot with the caret in \(cell)")
        }
    }

    /// With the header row active the row pill shares the button's line, so the
    /// button steps to sit entirely to the pill's left with a gap — anchored to
    /// the pill, not shifted a fixed amount from a slot whose distance from the
    /// pill shrinks with the line numbers off. Checked with them off (the
    /// default) precisely because that is the margin the fixed shift failed in.
    @Test("The button sits left of the pill on the header row")
    func buttonParksLeftOfThePill() {
        let editor = loadEditor(doc)
        #expect(!editor.showLineNumbers)   // the case the shift used to miss
        caret(editor, to: "c1")            // header row: the pill is on this line
        guard let button = editor.visibleTableRawButtons().first,
              let pill = editor.tableHandles().first(where: { $0.axis == .row }) else {
            Issue.record("no button or pill on the header row")
            return
        }
        #expect(button.rect.maxX <= pill.rect.minX,
                "the button overlaps the pill instead of sitting to its left")
        #expect(pill.rect.minX - button.rect.maxX >= editor.tableHandleGap - 0.5,
                "the button crowds the pill")
        #expect(button.rect.minX >= 0, "the button ran off the view's left edge")
    }

    /// View ▸ Zoom scales the theme's font sizes; the button follows the
    /// monospace size like the line numbers, and returns to its base at ⌘0.
    @Test("The button scales with zoom")
    func buttonScalesWithZoom() {
        let editor = loadEditor(doc)
        let base = editor.tableRawButtonSize
        #expect(base > 0)
        #expect(editor.visibleTableRawButtons().first?.rect.width == base)

        caret(editor, to: "a")
        let pill = editor.tableHandles().first { $0.axis == .row }?.rect.width
        let dot = editor.tableCellDotRadius

        var zoomed = editor.theme
        zoomed.fontSize *= 2
        zoomed.monospaceFontSize *= 2
        editor.applyTheme(zoomed, persist: false)
        ensureFullLayout(editor)
        layOutViewport(editor)
        #expect(editor.visibleTableRawButtons().first?.rect.width == base * 2,
                "the button did not grow with the zoomed theme")
        // The pills and the cell-selection dots follow the body size.
        #expect(editor.tableHandles().first { $0.axis == .row }?.rect.width == pill.map { $0 * 2 },
                "the row pill did not grow with the zoomed theme")
        #expect(editor.tableCellDotRadius == dot * 2)

        var actual = editor.theme
        actual.fontSize /= 2
        actual.monospaceFontSize /= 2
        editor.applyTheme(actual, persist: false)
        ensureFullLayout(editor)
        layOutViewport(editor)
        #expect(editor.visibleTableRawButtons().first?.rect.width == base)
    }

    /// The button toggles the table's raw markdown, and stays put afterwards so
    /// the same click brings the table back.
    @Test("The button toggles raw markdown both ways")
    func buttonTogglesRawMarkdown() {
        let editor = loadEditor(doc)
        caret(editor, to: "a")
        guard let table = editor.blocks.firstIndex(where: { $0.kind == .table }) else {
            Issue.record("no table")
            return
        }
        editor.activateRawTableEditing(blockIndex: table)
        #expect(editor.rawTableEditing)
        #expect(editor.tableRawButtonIsRevealed(blockIndex: table),
                "the button vanished once the table went raw, so nothing can toggle it back")
        editor.activateRawTableEditing(blockIndex: table)
        #expect(!editor.rawTableEditing)
    }
}
