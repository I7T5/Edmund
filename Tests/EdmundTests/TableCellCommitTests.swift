import Testing
import AppKit
@testable import EdmundCore

/// Writing a popup-edited cell back into the document.
///
/// The popover's own UI isn't exercised here — no test in this suite
/// synthesises events — so these drive `commitTableCell` directly, which is
/// everything between "the user finished typing" and the document changing.

@Suite("Table cell commit")
@MainActor
struct TableCellCommitTests {

    private let table = "| a | b |\n|---|---|\n| x | y |"

    private func load(_ text: String) -> EditorTextView {
        let editor = makeEditor()
        editor.loadContent(text)
        return editor
    }

    private func cell(_ editor: EditorTextView, at needle: String) -> TableCellRef? {
        let offset = (editor.rawSource as NSString).range(of: needle).location
        return editor.tableCell(atRawOffset: offset)
    }

    // MARK: - Sanitising

    @Test("Content is re-padded with single spaces")
    func repadsContent() {
        #expect(EditorTextView.sanitizedTableCellText("hello") == " hello ")
        #expect(EditorTextView.sanitizedTableCellText("   hello   ") == " hello ")
    }

    @Test("An emptied cell stays a cell")
    func emptyStaysACell() {
        #expect(EditorTextView.sanitizedTableCellText("") == " ")
        #expect(EditorTextView.sanitizedTableCellText("   ") == " ")
    }

    /// A GFM cell cannot span lines: a newline would end the row and turn one
    /// row into two.
    @Test("Newlines collapse to spaces")
    func newlinesBecomeSpaces() {
        #expect(EditorTextView.sanitizedTableCellText("a\nb") == " a b ")
        // "\r\n" is one Swift Character, so it collapses to one space.
        #expect(EditorTextView.sanitizedTableCellText("a\r\nb") == " a b ")
        #expect(EditorTextView.sanitizedTableCellText("a\u{2028}b") == " a b ")
    }

    /// An unescaped pipe would silently split the cell in two.
    @Test("A typed pipe is escaped")
    func pipeIsEscaped() {
        #expect(EditorTextView.sanitizedTableCellText("a | b") == " a \\| b ")
    }

    @Test("An already-escaped pipe is left alone")
    func escapedPipeUntouched() {
        #expect(EditorTextView.sanitizedTableCellText("a \\| b") == " a \\| b ")
    }

    // MARK: - Write-back

    @Test("Committing replaces just that cell")
    func replacesOneCell() {
        let editor = load(table)
        guard let target = cell(editor, at: "y") else {
            Issue.record("no cell")
            return
        }
        editor.commitTableCell(target, text: "zzz")
        #expect(editor.rawSource == "| a | b |\n|---|---|\n| x | zzz |")
    }

    @Test("The table still parses as a table afterwards")
    func staysATable() {
        let editor = load(table)
        guard let target = cell(editor, at: "b") else {
            Issue.record("no cell")
            return
        }
        editor.commitTableCell(target, text: "wide new header")
        #expect(editor.blocks.contains { $0.kind == .table })
    }

    /// A pipe typed into a cell must not restructure the table.
    @Test("A typed pipe does not add a column")
    func typedPipeKeepsTheShape() {
        let editor = load(table)
        guard let target = cell(editor, at: "x") else {
            Issue.record("no cell")
            return
        }
        editor.commitTableCell(target, text: "p | q")
        let firstRow = editor.rawSource.components(separatedBy: "\n")[2]
        #expect(splitTableRow(firstRow).count == 2)
        #expect(editor.rawSource.contains("\\|"))
    }

    /// Putting the caret inside the table would make it the active block and
    /// render it as raw markdown — exactly what the popover exists to avoid.
    @Test("The caret stays outside the table")
    func caretStaysOutside() {
        let editor = load("lead\n\n\(table)\n")
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        guard let target = cell(editor, at: "y") else {
            Issue.record("no cell")
            return
        }
        editor.commitTableCell(target, text: "zzz")

        let caret = editor.selectedRange().location
        #expect(caret == 2)
        let tableBlock = editor.blocks.firstIndex { $0.kind == .table }
        #expect(editor.blockIndexForRawOffset(caret) != tableBlock)
    }

    @Test("A caret after the edit shifts by the length change")
    func caretAfterTheEditShifts() {
        let editor = load("\(table)\n\ntrailing\n")
        let trailing = (editor.rawSource as NSString).range(of: "trailing").location
        editor.setSelectedRange(NSRange(location: trailing, length: 0))
        guard let target = cell(editor, at: "y") else {
            Issue.record("no cell")
            return
        }
        editor.commitTableCell(target, text: "zzz")
        #expect((editor.rawSource as NSString).range(of: "trailing").location
            == editor.selectedRange().location)
    }

    @Test("An unchanged cell is not an edit")
    func noChangeNoEdit() {
        let editor = load(table)
        let before = editor.rawSource
        guard let target = cell(editor, at: "y") else {
            Issue.record("no cell")
            return
        }
        editor.commitTableCell(target, text: "y")
        #expect(editor.rawSource == before)
    }

    @Test("One undo puts the original text back")
    func undoIsOneStep() {
        let editor = load(table)
        let before = editor.rawSource
        guard let target = cell(editor, at: "y") else {
            Issue.record("no cell")
            return
        }
        editor.commitTableCell(target, text: "zzz")
        #expect(editor.rawSource != before)
        editor.performUndo()
        #expect(editor.rawSource == before)
    }

    @Test("Committing into a stale cell range does nothing")
    func staleRangeIsIgnored() {
        let editor = load(table)
        guard let target = cell(editor, at: "y") else {
            Issue.record("no cell")
            return
        }
        editor.loadContent("something else entirely\n")
        editor.commitTableCell(target, text: "zzz")
        #expect(editor.rawSource == "something else entirely\n")
    }
}
