import Testing
import AppKit
@testable import EdmundCore

/// The handles hang off the grid, and the grid is read back off the same
/// `.tableRow` decoration the fragment draws its borders from — so what these
/// really check is that the two never drift apart.

@Suite("Table handles")
@MainActor
struct TableHandleTests {

    private let doc = "Intro.\n\n| c1 | c2 |\n| --- | --- |\n| a | b |\n| c | d |\n"

    private func loadEditor(_ text: String) -> EditorTextView {
        let editor = makeEditor()
        editor.updateContentInset()
        editor.loadContent(text)
        ensureFullLayout(editor)
        layOutViewport(editor)
        return editor
    }

    /// Puts the caret in a cell and lets the styling and layout catch up, the
    /// way a click would.
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

    // MARK: - The grid

    @Test("The grid has a rect per row and an edge per column boundary")
    func gridShape() {
        let editor = loadEditor(doc)
        guard let grid = editor.tableGrid(blockIndex: tableIndex(editor)) else {
            Issue.record("no grid")
            return
        }
        #expect(grid.rows.count == 4)        // header, separator, two body rows
        #expect(grid.columnEdges.count == 3) // left edge, one border, right edge
        #expect(grid.columns == 2)
        // Rows stack downward and do not overlap.
        for (above, below) in zip(grid.rows, grid.rows.dropFirst()) {
            #expect(below.minY >= above.maxY - 0.5)
        }
        // Column edges run left to right.
        for (left, right) in zip(grid.columnEdges, grid.columnEdges.dropFirst()) {
            #expect(right > left)
        }
    }

    /// The internal edges are the decoration's own offsets, which is what keeps
    /// a handle centred on the column the reader sees rather than on a
    /// re-measurement of it.
    @Test("Column edges come from the row decoration")
    func gridMatchesTheDecoration() {
        let editor = loadEditor(doc)
        let block = editor.blocks[tableIndex(editor)]
        guard let grid = editor.tableGrid(blockIndex: tableIndex(editor)),
              let decoration = editor.textStorage?.attribute(
                .blockDecoration, at: block.range.location, effectiveRange: nil) as? BlockDecoration,
              case .tableRow(let offsets, let width, let leftInset, _, _, _) = decoration.kind
        else {
            Issue.record("no decoration")
            return
        }
        #expect(offsets.count == grid.columnEdges.count - 2)
        // The decoration's offsets are measured from the row's text start; the
        // grid's from the table's left edge, one `leftInset` further left.
        for (offset, edge) in zip(offsets, grid.columnEdges.dropFirst()) {
            #expect(abs((edge - grid.columnEdges[0]) - (offset + leftInset)) < 0.5)
        }
        #expect(abs((grid.columnEdges.last! - grid.columnEdges[0]) - width) < 0.5)
    }

    /// The band the column handle sits in belongs to the header row's fragment
    /// but not to the table, or the handle would overlap the header.
    @Test("The reserved band is not part of the header row")
    func headerRowExcludesTheBand() {
        let editor = loadEditor(doc)
        guard let grid = editor.tableGrid(blockIndex: tableIndex(editor)),
              let header = grid.rows.first else {
            Issue.record("no grid")
            return
        }
        caret(editor, to: "c1")
        guard let column = editor.tableHandles().first(where: { $0.axis == .column }) else {
            Issue.record("no column handle")
            return
        }
        #expect(column.rect.maxY <= header.minY)
    }

    // MARK: - The handles

    @Test("A caret in a cell yields a row and a column handle")
    func handlesFollowTheActiveCell() {
        let editor = loadEditor(doc)
        caret(editor, to: "a")
        let handles = editor.tableHandles()
        #expect(handles.count == 2)
        #expect(handles.contains { $0.axis == .row })
        #expect(handles.contains { $0.axis == .column })
    }

    @Test("The handles sit outside the table")
    func handlesSitOutside() {
        let editor = loadEditor(doc)
        caret(editor, to: "b")
        guard let grid = editor.tableGrid(blockIndex: tableIndex(editor)) else {
            Issue.record("no grid")
            return
        }
        for handle in editor.tableHandles() {
            switch handle.axis {
            case .row:    #expect(handle.rect.maxX <= grid.columnEdges[0])
            case .column: #expect(handle.rect.maxY <= grid.rows[0].minY)
            }
        }
    }

    /// The row handle centres on the caret's row, the column handle on its
    /// column — so both move when the caret does.
    @Test("The handles move with the caret")
    func handlesTrackTheCaret() {
        let editor = loadEditor(doc)
        caret(editor, to: "| a")
        guard let firstRow = editor.tableHandles().first(where: { $0.axis == .row }),
              let firstColumn = editor.tableHandles().first(where: { $0.axis == .column })
        else {
            Issue.record("no handles")
            return
        }
        caret(editor, to: "d")
        guard let laterRow = editor.tableHandles().first(where: { $0.axis == .row }),
              let laterColumn = editor.tableHandles().first(where: { $0.axis == .column })
        else {
            Issue.record("no handles")
            return
        }
        #expect(laterRow.rect.midY > firstRow.rect.midY)     // a lower row
        #expect(laterColumn.rect.midX > firstColumn.rect.midX) // a righter column
        #expect(abs(laterRow.rect.minX - firstRow.rect.minX) < 0.5) // same margin slot
    }

    @Test("No handles with the caret outside a table")
    func noHandlesOutsideATable() {
        let editor = loadEditor(doc)
        caret(editor, to: "Intro")
        #expect(editor.tableHandles().isEmpty)
    }

    /// A raw table is showing its pipes; there is no grid to hang a handle off.
    @Test("No handles while the table is raw")
    func noHandlesWhenRaw() {
        let editor = loadEditor(doc)
        caret(editor, to: "c1")
        #expect(!editor.tableHandles().isEmpty)
        editor.rawTableEditing = true
        #expect(editor.tableHandles().isEmpty)
        #expect(editor.activeTableCell == nil)
    }

    // MARK: - Menus

    @Test("A row handle's menu offers the row operations")
    func rowMenuItems() {
        let editor = loadEditor(doc)
        caret(editor, to: "a")
        guard let handle = editor.tableHandles().first(where: { $0.axis == .row }) else {
            Issue.record("no row handle")
            return
        }
        let titles = editor.tableHandleMenu(handle).items.map(\.title)
        #expect(titles == ["Add Row Above", "Add Row Below", "Delete Row", "",
                           "Edit as Markdown"])
    }

    @Test("A column handle's menu offers the column operations")
    func columnMenuItems() {
        let editor = loadEditor(doc)
        caret(editor, to: "a")
        guard let handle = editor.tableHandles().first(where: { $0.axis == .column }) else {
            Issue.record("no column handle")
            return
        }
        let titles = editor.tableHandleMenu(handle).items.map(\.title)
        #expect(titles == ["Add Column Before", "Add Column After", "Delete Column", "",
                           "Edit as Markdown"])
    }

    /// The guards the operations enforce have to show up as a greyed item, not
    /// as a menu command that quietly does nothing.
    @Test("Delete is disabled where the operation would refuse")
    func deleteDisabledAtTheLimits() {
        let editor = loadEditor("Intro.\n\n| c1 |\n| --- |\n| a |\n")
        caret(editor, to: "| a")
        guard let column = editor.tableHandles().first(where: { $0.axis == .column }) else {
            Issue.record("no column handle")
            return
        }
        let item = editor.tableHandleMenu(column).items.first { $0.title == "Delete Column" }
        #expect(item?.isEnabled == false)   // the last column

        let bodyless = loadEditor("Intro.\n\n| c1 | c2 |\n| --- | --- |\n")
        caret(bodyless, to: "c1")
        guard let row = bodyless.tableHandles().first(where: { $0.axis == .row }) else {
            Issue.record("no row handle")
            return
        }
        let deleteRow = bodyless.tableHandleMenu(row).items.first { $0.title == "Delete Row" }
        #expect(deleteRow?.isEnabled == false)   // no body row to promote
    }

    /// "Add Row Below" on the header has to skip the separator, or the new row
    /// would land on line 1 and stop the block parsing as a table.
    @Test("Add Row Below on the header targets the first body row")
    func addRowBelowHeaderSkipsSeparator() {
        let editor = loadEditor(doc)
        caret(editor, to: "c1")
        guard let handle = editor.tableHandles().first(where: { $0.axis == .row }),
              let item = editor.tableHandleMenu(handle).items
                .first(where: { $0.title == "Add Row Below" }),
              let op = item.representedObject as? TableOperation else {
            Issue.record("no operation")
            return
        }
        #expect(op.row == 2)
        editor.performTableOperation(item)
        #expect(editor.rawSource
                == "Intro.\n\n| c1 | c2 |\n| --- | --- |\n|  |  |\n| a | b |\n| c | d |\n")
        #expect(editor.blocks.contains { $0.kind == .table })
    }
}
