import Testing
import AppKit
@testable import EdmundCore

/// Picking a whole row or column through its pill, and moving one by dragging
/// it, after Notes (misc/frontend-refs/notes-table-*-selection-by-pill.png).

@Suite("Table row and column selection")
@MainActor
struct TableAxisSelectionTests {

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

    private func tableIndex(_ editor: EditorTextView) -> Int {
        editor.blocks.firstIndex { $0.kind == .table } ?? -1
    }

    private func handle(_ editor: EditorTextView, _ axis: TableHandle.Axis) -> TableHandle? {
        editor.tableHandles().first { $0.axis == axis }
    }

    // MARK: - Selecting

    @Test("A row pill selects its whole row")
    func rowPillSelectsTheRow() throws {
        let editor = loadEditor(doc)
        caret(editor, to: "| c |")
        let pill = try #require(handle(editor, .row))
        editor.selectTableAxis(for: pill)
        let selection = try #require(editor.tableAxisSelection)
        #expect(selection.axis == .row)
        #expect(selection.block.rows == 3...3)
        #expect(selection.block.columns == 0...1)
        let ns = editor.rawSource as NSString
        let picked = editor.selectedRanges.map { ns.substring(with: $0.rangeValue) }
        #expect(picked == [" c | d "])   // cell to cell, never over a pipe at the ends
    }

    @Test("A column pill selects its whole column, header included")
    func columnPillSelectsTheColumn() throws {
        let editor = loadEditor(doc)
        caret(editor, to: "b")
        let pill = try #require(handle(editor, .column))
        editor.selectTableAxis(for: pill)
        let selection = try #require(editor.tableAxisSelection)
        #expect(selection.axis == .column)
        #expect(selection.block.columns == 1...1)
        let ns = editor.rawSource as NSString
        let picked = editor.selectedRanges.map {
            ns.substring(with: $0.rangeValue).trimmingCharacters(in: .whitespaces)
        }
        #expect(picked == ["c2", "b", "d"])
    }

    /// Notes turns the clicked pill into a tab standing on the selection box
    /// and keeps the other axis's pill where the caret was.
    @Test("A selected row wears a tab, and the column pill stays")
    func selectedRowShowsATabAndTheOtherPill() throws {
        let editor = loadEditor(doc)
        caret(editor, to: "| c |")
        editor.selectTableAxis(for: try #require(handle(editor, .row)))
        let handles = editor.tableHandles()
        let tab = try #require(handles.first { $0.selected })
        #expect(tab.axis == .row)
        #expect(tab.span == 3...3)
        let column = try #require(handles.first { !$0.selected })
        #expect(column.axis == .column)
        #expect(column.column == 0)

        let box = try #require(editor.tableCellSelectionBox())
        #expect(abs(tab.rect.maxX - box.minX) < 0.5)        // flush on the box
        #expect(abs(tab.rect.minY - box.minY) < 0.5)
        #expect(abs(tab.rect.height - box.height) < 0.5)   // as tall as the row
        // Its full thickness unless the view's edge clips it.
        #expect(tab.rect.width > 0)
        #expect(tab.rect.width <= editor.tableHandleSelectedThickness + 0.5)
    }

    @Test("A selected column's tab sits on top of it, inside the reserved band")
    func selectedColumnTabSitsInTheBand() throws {
        let editor = loadEditor(doc)
        caret(editor, to: "b")
        editor.selectTableAxis(for: try #require(handle(editor, .column)))
        let tab = try #require(editor.tableHandles().first { $0.selected })
        let grid = try #require(editor.tableGrid(blockIndex: tableIndex(editor)))
        let box = try #require(editor.tableCellSelectionBox())
        #expect(abs(tab.rect.maxY - grid.rows[0].minY) < 0.5)
        #expect(abs(tab.rect.width - box.width) < 0.5)
        #expect(editor.tableHandleBand >= editor.tableHandleSelectedThickness)
    }

    @Test("Any other selection retires the picked row")
    func anotherSelectionEndsIt() throws {
        let editor = loadEditor(doc)
        caret(editor, to: "| c |")
        editor.selectTableAxis(for: try #require(handle(editor, .row)))
        #expect(editor.tableAxisSelection != nil)
        caret(editor, to: "a")
        #expect(editor.tableAxisSelection == nil)
        #expect(editor.tableHandles().allSatisfy { !$0.selected })
    }

    /// A drag across a full row is a block of cells, not a picked row: the
    /// tab is the pill's, and the pills stay off screen as before.
    @Test("A drag-selected full row has no tab")
    func dragSelectedRowIsNotPicked() {
        let editor = loadEditor(doc)
        caret(editor, to: "a")
        let ns = editor.rawSource as NSString
        let from = ns.range(of: "c |").location
        editor.setSelectedRange(NSRange(location: from,
                                        length: ns.range(of: "d").location + 1 - from))
        #expect(editor.tableAxisSelection == nil)
        #expect(editor.tableHandles().isEmpty)
    }

    @Test("A selected row's tab menu deletes every row it stands for")
    func tabMenuDeletesTheRun() throws {
        let editor = loadEditor(doc)
        editor.selectTableAxis(.row, blockIndex: tableIndex(editor), span: 2...3,
                               anchor: (2, 0))
        let tab = try #require(editor.tableHandles().first { $0.selected })
        let titles = editor.tableHandleMenu(tab).items.map(\.title)
        #expect(titles == ["Add Row Above", "Add Row Below", "", "Delete Rows"])
        let delete = try #require(editor.tableHandleMenu(tab).items.last)
        editor.performTableOperation(delete)
        #expect(editor.rawSource == "Intro.\n\n| c1 | c2 |\n| --- | --- |\n")
    }

    @Test("Every column of a table cannot be deleted from its tab")
    func cannotDeleteEveryColumn() throws {
        let editor = loadEditor(doc)
        editor.selectTableAxis(.column, blockIndex: tableIndex(editor), span: 0...1,
                               anchor: (2, 0))
        let tab = try #require(editor.tableHandles().first { $0.selected })
        let delete = editor.tableHandleMenu(tab).items.first { $0.title == "Delete Columns" }
        #expect(delete?.isEnabled == false)
    }

    // MARK: - Moving

    @Test("Rows move byte for byte, the separator staying on line 1")
    func movedRows() {
        let lines = ["| h1 | h2 |", "| :-- | --: |", "| a | b |", "| c  | d |", "| e | f |"]
        // Last body row to the top of the body.
        #expect(movedTableRows(lines, from: 3...3, to: 1)
                == ["| h1 | h2 |", "| :-- | --: |", "| e | f |", "| a | b |", "| c  | d |"])
        // A body row to the top becomes the header.
        #expect(movedTableRows(lines, from: 2...2, to: 0)
                == ["| c  | d |", "| :-- | --: |", "| h1 | h2 |", "| a | b |", "| e | f |"])
        // The header to the end.
        #expect(movedTableRows(lines, from: 0...0, to: 4)
                == ["| a | b |", "| :-- | --: |", "| c  | d |", "| e | f |", "| h1 | h2 |"])
        // Dropped where it started: nothing to do.
        #expect(movedTableRows(lines, from: 1...2, to: 1) == nil)
        #expect(movedTableRows(lines, from: 1...2, to: 3) == nil)
    }

    @Test("Columns move with their alignment, ragged rows filled first")
    func movedColumns() {
        let lines = ["| h1 | h2 | h3 |", "| :-- | :-: | --: |", "| a | b | c |", "| x |"]
        #expect(movedTableColumns(lines, from: 2...2, to: 0)
                == ["| h3 | h1 | h2 |", "| --: | :-- | :-: |", "| c | a | b |", "|  | x |  |"])
        #expect(movedTableColumns(lines, from: 0...0, to: 3)
                == ["| h2 | h3 | h1 |", "| :-: | --: | :-- |", "| b | c | a |", "|  |  | x |"])
        #expect(movedTableColumns(lines, from: 1...1, to: 2) == nil)
    }

    @Test("An escaped pipe stays inside the column it belongs to")
    func movedColumnKeepsEscapedPipe() {
        let lines = ["| h1 | h2 |", "| --- | --- |", "| a \\| b | c |"]
        #expect(movedTableColumns(lines, from: 1...1, to: 0)
                == ["| h2 | h1 |", "| --- | --- |", "| c | a \\| b |"])
    }

    @Test("A table without outer pipes keeps none")
    func movedColumnWithoutOuterPipes() {
        let lines = ["h1 | h2", "--- | ---", "a | b"]
        #expect(movedTableColumns(lines, from: 1...1, to: 0)
                == [" h2|h1 ", " ---|--- ", " b|a "])
    }

    @Test("Dropping a moved row is one undo step")
    func moveIsOneUndoStep() throws {
        let editor = loadEditor(doc)
        let t = tableIndex(editor)
        let lines = try #require(editor.tableLines(blockIndex: t))
        editor.replaceTable(blockIndex: t,
                            lines: try #require(movedTableRows(lines, from: 2...2, to: 1)))
        #expect(editor.rawSource
                == "Intro.\n\n| c1 | c2 |\n| --- | --- |\n| c | d |\n| a | b |\n")
        editor.undo(nil)
        #expect(editor.rawSource == doc)
    }
}
