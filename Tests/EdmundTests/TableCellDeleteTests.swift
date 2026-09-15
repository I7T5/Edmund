import Testing
import AppKit
@testable import EdmundCore

/// Delete with a block of cells selected, after Apple Notes: a complete row or
/// column whose cells are already empty is removed; every other case clears the
/// cells' contents and keeps them selected. So the first Delete empties a full
/// row/column and a second removes it.

@Suite("Table cell-selection delete")
@MainActor
struct TableCellDeleteTests {

    // 3 columns, header + 3 body rows. Line indices: 0 header, 1 separator,
    // 2/3/4 body.
    private let doc = """
    | a | b | c |
    | --- | --- | --- |
    | 1 | 2 | 3 |
    | 4 | 5 | 6 |
    | 7 | 8 | 9 |

    """

    private func loadEditor() -> EditorTextView {
        let editor = makeEditor()
        editor.updateContentInset()
        editor.loadContent(doc)
        ensureFullLayout(editor)
        layOutViewport(editor)
        return editor
    }

    private func table(_ editor: EditorTextView) -> Int {
        editor.blocks.firstIndex { $0.kind == .table }!
    }

    @Test("A full column selected clears the column, grid intact")
    func fullColumnClears() {
        let editor = loadEditor()
        let t = table(editor)
        editor.selectTableCells(blockIndex: t, from: (0, 1), to: (4, 1))
        #expect(editor.tableCellSelection != nil)
        editor.deleteBackward(nil)
        #expect(editor.rawSource.contains("| a |  | c |"))
        #expect(editor.rawSource.contains("| 1 |  | 3 |"))
        #expect(editor.rawSource.contains("| 7 |  | 9 |"))
        // Still three columns — the column was cleared, not removed.
        #expect(editor.tableColumnCount(blockIndex: table(editor)) == 3)
    }

    @Test("A full row selected clears the row, grid intact")
    func fullRowClears() {
        let editor = loadEditor()
        let t = table(editor)
        editor.selectTableCells(blockIndex: t, from: (2, 0), to: (2, 2))
        editor.deleteBackward(nil)
        #expect(editor.rawSource.contains("|  |  |  |\n| 4 | 5 | 6 |"))
        #expect(editor.rawSource.contains("| 7 | 8 | 9 |"))
        // Header and separator untouched; still five lines.
        #expect(editor.rawSource.contains("| a | b | c |\n| --- | --- | --- |"))
        #expect(editor.tableLines(blockIndex: table(editor))?.count == 5)
    }

    @Test("A partial block clears its cells' contents")
    func partialBlockClears() {
        let editor = loadEditor()
        let t = table(editor)
        // Rows 2-3, columns 0-1: 1,2 / 4,5.
        editor.selectTableCells(blockIndex: t, from: (2, 0), to: (3, 1))
        editor.deleteBackward(nil)
        #expect(editor.rawSource.contains("|  |  | 3 |"))
        #expect(editor.rawSource.contains("|  |  | 6 |"))
        // The untouched cells and the structure survive.
        #expect(editor.rawSource.contains("| 7 | 8 | 9 |"))
        #expect(editor.rawSource.contains("| a | b | c |\n| --- | --- | --- |"))
        #expect(editor.blocks.contains { $0.kind == .table })
    }

    @Test("The whole table selected clears rather than deleting itself")
    func wholeTableClears() {
        let editor = loadEditor()
        let t = table(editor)
        editor.selectTableCells(blockIndex: t, from: (0, 0), to: (4, 2))
        editor.deleteBackward(nil)
        // Every cell blank, but the grid — 5 rows, the separator, 3 columns —
        // is intact.
        #expect(editor.rawSource.contains("|  |  |  |\n| --- | --- | --- |\n|  |  |  |"))
        let t2 = table(editor)
        #expect(editor.tableColumnCount(blockIndex: t2) == 3)
        #expect(editor.tableLines(blockIndex: t2)?.count == 5)
    }

    @Test("An empty complete column is deleted")
    func emptyColumnDeletes() {
        let editor = makeEditor()
        editor.updateContentInset()
        editor.loadContent("| a |  | c |\n| --- | --- | --- |\n| 1 |  | 3 |\n| 4 |  | 6 |\n")
        ensureFullLayout(editor); layOutViewport(editor)
        let t = table(editor)
        editor.selectTableCells(blockIndex: t, from: (0, 1), to: (3, 1))
        editor.deleteBackward(nil)
        #expect(editor.rawSource.contains("| a | c |"))
        #expect(editor.rawSource.contains("| 1 | 3 |"))
        #expect(editor.tableColumnCount(blockIndex: table(editor)) == 2)
    }

    @Test("An empty complete row is deleted")
    func emptyRowDeletes() {
        let editor = makeEditor()
        editor.updateContentInset()
        editor.loadContent("| a | b |\n| --- | --- |\n|  |  |\n| 4 | 5 |\n")
        ensureFullLayout(editor); layOutViewport(editor)
        let t = table(editor)
        editor.selectTableCells(blockIndex: t, from: (2, 0), to: (2, 1))
        editor.deleteBackward(nil)
        #expect(!editor.rawSource.contains("|  |  |"))
        #expect(editor.rawSource.contains("| 4 | 5 |"))
        #expect(editor.tableLines(blockIndex: table(editor))?.count == 3)  // header, sep, one body
    }

    /// The Notes two-press: a full row with content clears on the first Delete
    /// (and stays selected), then is removed on the second.
    @Test("Two Deletes clear then remove a full row")
    func twoPressRemovesRow() {
        let editor = loadEditor()
        let t = table(editor)
        editor.selectTableCells(blockIndex: t, from: (2, 0), to: (2, 2))
        editor.deleteBackward(nil)
        #expect(editor.rawSource.contains("|  |  |  |\n| 4 | 5 | 6 |"))  // cleared
        #expect(editor.tableCellSelection != nil, "the cells lost their selection")
        editor.deleteBackward(nil)
        #expect(!editor.rawSource.contains("|  |  |  |"))                // removed
        #expect(editor.rawSource.contains("| 4 | 5 | 6 |"))
        #expect(editor.tableLines(blockIndex: table(editor))?.count == 4)  // one row fewer
    }

    @Test("One undo restores the table")
    func undoRestores() {
        let editor = loadEditor()
        let t = table(editor)
        let before = editor.rawSource
        editor.selectTableCells(blockIndex: t, from: (2, 0), to: (3, 1))
        editor.deleteBackward(nil)
        #expect(editor.rawSource != before)
        editor.undo(nil)
        #expect(editor.rawSource == before)
    }

    @Test("Forward delete behaves the same on a cell selection")
    func forwardDeleteClears() {
        let editor = loadEditor()
        let t = table(editor)
        editor.selectTableCells(blockIndex: t, from: (2, 0), to: (3, 1))
        editor.deleteForward(nil)
        #expect(editor.rawSource.contains("|  |  | 3 |"))
    }

    /// No cell block selected → an ordinary delete, untouched by this path.
    @Test("A plain caret delete is left alone")
    func plainDeleteUntouched() {
        let editor = loadEditor()
        let caret = (editor.rawSource as NSString).range(of: "5").upperBound
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        #expect(editor.tableCellSelection == nil)
        editor.deleteBackward(nil)
        #expect(editor.rawSource.contains("|  |"))   // the 5 was deleted in place
    }
}
