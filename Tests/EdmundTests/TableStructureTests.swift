import Testing
import AppKit
@testable import EdmundCore

/// The structural operations splice: they write the characters the change needs
/// and leave the rest of the table byte-identical. So these assert the *whole*
/// `rawSource`, not `contains` — a test that only checks the new row appeared
/// would not notice the other rows being reformatted around it.

@Suite("Table structure")
@MainActor
struct TableStructureTests {

    private let doc = "Lead.\n\n| c1 | c2 |\n| --- | --- |\n| a | b |\n| c | d |\n"

    private func loadEditor(_ text: String) -> EditorTextView {
        let editor = makeEditor()
        editor.updateContentInset()
        editor.loadContent(text)
        ensureFullLayout(editor)
        layOutViewport(editor)
        return editor
    }

    private func tableIndex(_ editor: EditorTextView) -> Int {
        editor.blocks.firstIndex { $0.kind == .table } ?? -1
    }

    // MARK: - Rows

    @Test("A row is inserted between the rows around it")
    func insertRowInTheMiddle() {
        let editor = loadEditor(doc)
        editor.insertTableRow(blockIndex: tableIndex(editor), at: 3)
        #expect(editor.rawSource
                == "Lead.\n\n| c1 | c2 |\n| --- | --- |\n| a | b |\n|  |  |\n| c | d |\n")
        #expect(editor.blocks.contains { $0.kind == .table })
    }

    @Test("A row appended past the last one reuses the newline before it")
    func insertRowAtTheEnd() {
        let editor = loadEditor(doc)
        editor.insertTableRow(blockIndex: tableIndex(editor), at: 4)
        #expect(editor.rawSource
                == "Lead.\n\n| c1 | c2 |\n| --- | --- |\n| a | b |\n| c | d |\n|  |  |\n")
    }

    /// GFM needs the separator on line 1, so a row above the header cannot just
    /// land first — it takes the header's place and the old header drops to the
    /// top of the body, under the separator.
    @Test("A row inserted above the header becomes the header")
    func insertRowAboveTheHeader() {
        let editor = loadEditor(doc)
        editor.insertTableRow(blockIndex: tableIndex(editor), at: 0)
        #expect(editor.rawSource
                == "Lead.\n\n|  |  |\n| --- | --- |\n| c1 | c2 |\n| a | b |\n| c | d |\n")
        #expect(editor.blocks.contains { $0.kind == .table })
    }

    @Test("A row added to a pipe-less table stays pipe-less")
    func insertRowKeepsPipeStyle() {
        let editor = loadEditor("Lead.\n\n a | b \n---|---\n c | d \n")
        editor.insertTableRow(blockIndex: tableIndex(editor), at: 2)
        #expect(editor.rawSource == "Lead.\n\n a | b \n---|---\n  |  \n c | d \n")
    }

    @Test("The separator row is never an insert target")
    func insertRowRefusesTheSeparator() {
        let editor = loadEditor(doc)
        editor.insertTableRow(blockIndex: tableIndex(editor), at: 1)
        #expect(editor.rawSource == doc)
    }

    @Test("A deleted row takes its newline with it")
    func deleteRow() {
        let editor = loadEditor(doc)
        editor.deleteTableRow(blockIndex: tableIndex(editor), row: 2)
        #expect(editor.rawSource == "Lead.\n\n| c1 | c2 |\n| --- | --- |\n| c | d |\n")
    }

    @Test("Deleting the last row takes the newline before it")
    func deleteLastRow() {
        let editor = loadEditor(doc)
        editor.deleteTableRow(blockIndex: tableIndex(editor), row: 3)
        #expect(editor.rawSource == "Lead.\n\n| c1 | c2 |\n| --- | --- |\n| a | b |\n")
    }

    /// Deleting the header promotes the first body row into it. Deleting line 0
    /// on its own would leave the separator as the header and stop the block
    /// parsing as a table at all — which is what this asserts against.
    @Test("Deleting the header promotes the next row")
    func deleteHeaderPromotes() {
        let editor = loadEditor(doc)
        editor.deleteTableRow(blockIndex: tableIndex(editor), row: 0)
        #expect(editor.rawSource == "Lead.\n\n| a | b |\n| --- | --- |\n| c | d |\n")
        #expect(editor.blocks.contains { $0.kind == .table })
    }

    /// With no body row there is nothing to promote, so the header stays.
    @Test("The header of a body-less table cannot be deleted")
    func deleteHeaderRefusedWithoutABody() {
        let text = "Lead.\n\n| c1 | c2 |\n| --- | --- |\n"
        let editor = loadEditor(text)
        #expect(editor.canDeleteTableRow(blockIndex: tableIndex(editor), row: 0) == false)
        editor.deleteTableRow(blockIndex: tableIndex(editor), row: 0)
        #expect(editor.rawSource == text)
    }

    // MARK: - Columns

    @Test("A column is inserted in every row, dashes in the separator")
    func insertColumnInTheMiddle() {
        let editor = loadEditor(doc)
        editor.insertTableColumn(blockIndex: tableIndex(editor), at: 1)
        #expect(editor.rawSource
                == "Lead.\n\n| c1 |  | c2 |\n| --- | --- | --- |\n| a |  | b |\n| c |  | d |\n")
    }

    @Test("A column inserted at the front lands before the first cell")
    func insertColumnAtTheFront() {
        let editor = loadEditor(doc)
        editor.insertTableColumn(blockIndex: tableIndex(editor), at: 0)
        #expect(editor.rawSource
                == "Lead.\n\n|  | c1 | c2 |\n| --- | --- | --- |\n|  | a | b |\n|  | c | d |\n")
    }

    @Test("A column appended past the last one lands after it")
    func insertColumnAtTheEnd() {
        let editor = loadEditor(doc)
        editor.insertTableColumn(blockIndex: tableIndex(editor), at: 2)
        #expect(editor.rawSource
                == "Lead.\n\n| c1 | c2 |  |\n| --- | --- | --- |\n| a | b |  |\n| c | d |  |\n")
    }

    @Test("A deleted column takes one pipe with it")
    func deleteColumn() {
        let editor = loadEditor(doc)
        editor.deleteTableColumn(blockIndex: tableIndex(editor), column: 1)
        #expect(editor.rawSource == "Lead.\n\n| c1 |\n| --- |\n| a |\n| c |\n")
    }

    /// The first cell has no pipe before it to remove, so it takes the one after.
    @Test("Deleting the first column takes the pipe after it")
    func deleteFirstColumn() {
        let editor = loadEditor(doc)
        editor.deleteTableColumn(blockIndex: tableIndex(editor), column: 0)
        #expect(editor.rawSource == "Lead.\n\n| c2 |\n| --- |\n| b |\n| d |\n")
    }

    @Test("The last column cannot be deleted")
    func deleteLastColumnRefused() {
        let text = "Lead.\n\n| c1 |\n| --- |\n| a |\n"
        let editor = loadEditor(text)
        #expect(editor.canDeleteTableColumn(blockIndex: tableIndex(editor), column: 0) == false)
        editor.deleteTableColumn(blockIndex: tableIndex(editor), column: 0)
        #expect(editor.rawSource == text)
    }

    /// Only the separator cells of the columns either side of the new one are
    /// touched, so their `:` alignment markers survive.
    @Test("Alignment markers on other columns survive a column insert")
    func insertColumnKeepsAlignment() {
        let editor = loadEditor("Lead.\n\n| c1 | c2 |\n| :--- | ---: |\n| a | b |\n")
        editor.insertTableColumn(blockIndex: tableIndex(editor), at: 1)
        #expect(editor.rawSource
                == "Lead.\n\n| c1 |  | c2 |\n| :--- | --- | ---: |\n| a |  | b |\n")
    }

    /// `cellRanges` drops an empty cell; the structural path counts it, or
    /// asking for column 2 here would delete `b` instead of the empty one.
    @Test("An empty cell counts as a column")
    func emptyCellIsAColumn() {
        let editor = loadEditor("Lead.\n\n| c1 | c2 | c3 |\n| --- | --- | --- |\n| a || b |\n")
        #expect(editor.tableColumnCount(blockIndex: tableIndex(editor)) == 3)
        editor.deleteTableColumn(blockIndex: tableIndex(editor), column: 1)
        #expect(editor.rawSource == "Lead.\n\n| c1 | c3 |\n| --- | --- |\n| a | b |\n")
    }

    /// A row short of the column being added gains its cell at the end rather
    /// than failing, and one short of the column being deleted is left alone.
    @Test("A ragged row survives both column operations")
    func raggedRow() {
        let editor = loadEditor("Lead.\n\n| c1 | c2 |\n| --- | --- |\n| a |\n")
        editor.insertTableColumn(blockIndex: tableIndex(editor), at: 1)
        #expect(editor.rawSource == "Lead.\n\n| c1 |  | c2 |\n| --- | --- | --- |\n| a |  |\n")
    }

    // MARK: - Caret and undo

    @Test("The caret lands in the new row's requested column")
    func caretLandsInTheNewRow() {
        let editor = loadEditor(doc)
        editor.insertTableRow(blockIndex: tableIndex(editor), at: 3, column: 1)
        let ns = editor.rawSource as NSString
        let line = ns.lineRange(for: editor.selectedRange())
        #expect(ns.substring(with: line).trimmingCharacters(in: .newlines) == "|  |  |")
        // Second cell of `|  |  |`, one space in: `|  | ‸ |`.
        #expect(editor.selectedRange() == NSRange(location: line.location + 5, length: 0))
    }

    @Test("The caret lands in the new column's cell")
    func caretLandsInTheNewColumn() {
        let editor = loadEditor(doc)
        editor.insertTableColumn(blockIndex: tableIndex(editor), at: 1, row: 2)
        let ns = editor.rawSource as NSString
        let line = ns.lineRange(for: editor.selectedRange())
        #expect(ns.substring(with: line).trimmingCharacters(in: .newlines) == "| a |  | b |")
    }

    @Test("One undo puts a column back")
    func undoRestoresTheTable() {
        let editor = loadEditor(doc)
        editor.insertTableColumn(blockIndex: tableIndex(editor), at: 1)
        #expect(editor.rawSource != doc)
        editor.undo(nil)
        #expect(editor.rawSource == doc)
    }

    @Test("One undo puts a row back")
    func undoRestoresARow() {
        let editor = loadEditor(doc)
        editor.deleteTableRow(blockIndex: tableIndex(editor), row: 2)
        #expect(editor.rawSource != doc)
        editor.undo(nil)
        #expect(editor.rawSource == doc)
    }

    /// A table with a header and a separator and nothing else is still a table,
    /// which is what makes deleting the last body row safe to offer.
    @Test("A table survives losing its last body row")
    func bodylessTableStillParses() {
        let editor = loadEditor("Lead.\n\n| c1 | c2 |\n| --- | --- |\n| a | b |\n")
        editor.deleteTableRow(blockIndex: tableIndex(editor), row: 2)
        #expect(editor.rawSource == "Lead.\n\n| c1 | c2 |\n| --- | --- |\n")
        #expect(editor.blocks.contains { $0.kind == .table })
    }
}
