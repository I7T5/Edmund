import Testing
import AppKit
@testable import EdmundCore

/// Copying out of a table. The storage is markdown, so an untouched ⌘C hands
/// the next app a row of pipes; these are the two cases worth more than that.
///
/// The pure text is what is checked, not the pasteboard: a test suite has no
/// business overwriting the clipboard of whoever is running it.

@Suite("Table copy")
@MainActor
struct TableCopyTests {

    private let doc = "Intro.\n\n| h1 | h2 |\n| --- | --- |\n| a | b |\n| c | d |\n"

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

    private func tableIndex(_ editor: EditorTextView) -> Int {
        editor.blocks.firstIndex { $0.kind == .table } ?? -1
    }

    @Test("The caret in a cell copies that cell's content")
    func caretCopiesTheCell() {
        let editor = loadEditor(doc)
        caret(editor, to: "a")
        #expect(editor.tableCopyText() == "a")
        caret(editor, to: "h2")
        #expect(editor.tableCopyText() == "h2")
    }

    /// The padding a column adds is a kerned space in the storage, and the
    /// author's own spaces sit around the content too. Neither is content.
    @Test("A copied cell carries no padding and no pipes")
    func copiedCellIsTrimmed() {
        let editor = loadEditor("Intro.\n\n| h1 | h2 |\n| --- | --- |\n|   wide   | b |\n")
        caret(editor, to: "wide")
        let copied = editor.tableCopyText()
        #expect(copied == "wide")
        #expect(copied?.contains("|") == false)
    }

    @Test("A block of cells copies as tab-separated rows")
    func blockCopiesAsTSV() {
        let editor = loadEditor(doc)
        caret(editor, to: "a")
        editor.selectTableCells(blockIndex: tableIndex(editor), from: (2, 0), to: (3, 1))
        #expect(editor.tableCellSelection != nil)
        #expect(editor.tableCopyText() == "a\tb\nc\td")
    }

    /// A block reaching the header takes the header's labels with it — a
    /// spreadsheet wants them — but the separator row has no cells to look up
    /// and must not paste as a row of dashes.
    @Test("A block across the header skips the separator row")
    func blockSkipsTheSeparator() {
        let editor = loadEditor(doc)
        caret(editor, to: "h1")
        editor.selectTableCells(blockIndex: tableIndex(editor), from: (0, 0), to: (2, 1))
        let copied = editor.tableCopyText()
        #expect(copied == "h1\th2\na\tb")
        #expect(copied?.contains("---") == false)
    }

    /// A tab inside a cell would otherwise read as a column break.
    @Test("A cell carrying a tab is quoted")
    func tabbedCellIsQuoted() {
        let editor = loadEditor("Intro.\n\n| h1 | h2 |\n| --- | --- |\n| a\tb | c |\n")
        caret(editor, to: "c |")
        editor.selectTableCells(blockIndex: tableIndex(editor), from: (2, 0), to: (2, 1))
        #expect(editor.tableCopyText() == "\"a\tb\"\tc")
    }

    /// Everything else is an ordinary copy: a selection inside one cell is just
    /// text, and outside a table there is nothing to do.
    @Test("Ordinary selections are left to the normal copy")
    func ordinarySelectionsFallThrough() {
        let editor = loadEditor(doc)
        caret(editor, to: "a")
        let text = (editor.rawSource as NSString).range(of: "a")
        editor.setSelectedRange(text)
        #expect(editor.tableCopyText() == nil)

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(editor.tableCopyText() == nil)
        editor.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(editor.tableCopyText() == nil)
    }

    /// With the table showing its markdown the pipes are the content, and a
    /// copy has to hand over exactly what is on screen.
    @Test("A raw table copies as ordinary text")
    func rawTableFallsThrough() {
        let editor = loadEditor(doc)
        caret(editor, to: "a")
        editor.activateRawTableEditing(blockIndex: tableIndex(editor))
        #expect(editor.rawTableEditing)
        #expect(editor.tableCopyText() == nil)
    }
}
