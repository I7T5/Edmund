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
