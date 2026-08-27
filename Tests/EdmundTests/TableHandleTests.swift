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

    // MARK: - The caret in a cell's padding

    /// A column pads by kerning the cell's last character, so that one space
    /// can be hundreds of points wide and a click past its midpoint puts the
    /// caret at the far end of it — drawn out in the middle of the cell rather
    /// than against the text. Measured before the fix: the caret for the cell
    /// end sat at x=652 in a cell spanning 459…802.
    @Test("A caret in a cell's trailing pad snaps back to the text")
    func caretSnapsOutOfThePad() {
        let editor = loadEditor("Intro.\n\n| c1 | c2 |\n| --- | --- |\n| c21 | b |\n")
        let ns = editor.rawSource as NSString
        guard let cell = editor.tableCell(atRawOffset: ns.range(of: "c21").location) else {
            Issue.record("no cell")
            return
        }
        let afterText = ns.range(of: "c21").upperBound
        // The cell's own end is past the text; it comes back to just after "1".
        #expect(editor.tableCellCaretSnap(cell.contentRange.upperBound) == afterText)
        // A caret already on the text is left alone.
        #expect(editor.tableCellCaretSnap(afterText) == nil)
        #expect(editor.tableCellCaretSnap(cell.contentRange.location) == nil)
    }

    /// An all-blank cell has no text to snap to, so it keeps one space — the
    /// same rule `selectCellText` uses, so typing does not eat the pad before
    /// the closing pipe.
    @Test("An empty cell snaps one space in, not to its far end")
    func emptyCellSnapsOneSpaceIn() {
        let editor = loadEditor("Intro.\n\n| c1 | c2 |\n| --- | --- |\n|    | b |\n")
        let ns = editor.rawSource as NSString
        let row = ns.range(of: "|    |").location
        guard let cell = editor.tableCell(atRawOffset: row + 2) else {
            Issue.record("no cell")
            return
        }
        #expect(editor.tableCellCaretSnap(cell.contentRange.upperBound)
                == cell.contentRange.location + 1)
    }

    @Test("Nothing snaps outside a table")
    func noSnapOutsideATable() {
        let editor = loadEditor(doc)
        #expect(editor.tableCellCaretSnap((editor.rawSource as NSString)
                                            .range(of: "Intro").location + 2) == nil)
    }

    // MARK: - Cell selection

    /// A selection that stops inside two different cells is widened to cover
    /// both whole — the box has to be able to say what a Copy would take — and
    /// is installed as one range per row. A single range spanning both rows
    /// would cover row 2 through its newline, and AppKit runs the highlight of
    /// such a line out to the text container's edge, far past the table.
    @Test("A cross-cell selection snaps to whole cells, one range per row")
    func crossCellSelectionSnaps() {
        let editor = loadEditor(doc)
        let ns = editor.rawSource as NSString
        let from = ns.range(of: "a").location
        let to = ns.range(of: "d").location + 1
        editor.setSelectedRange(NSRange(location: from, length: to - from))

        let ranges = editor.selectedRanges.map(\.rangeValue)
        #expect(ranges.count == 2)
        for (range, row) in zip(ranges, [2, 3]) {
            guard let first = editor.tableCell(blockIndex: tableIndex(editor), row: row, column: 0),
                  let last = editor.tableCell(blockIndex: tableIndex(editor), row: row, column: 1)
            else {
                Issue.record("no cells in row \(row)")
                continue
            }
            #expect(range == NSRange(
                location: first.contentRange.location,
                length: last.contentRange.upperBound - first.contentRange.location))
            // Stops at the last cell, never over the newline that ends the row.
            #expect(ns.character(at: range.upperBound) != 0x0A)
        }
        // Idempotent, or a drag tick would creep the selection.
        editor.setSelectedRanges(editor.selectedRanges, affinity: .downstream,
                                 stillSelecting: false)
        #expect(editor.selectedRanges.map(\.rangeValue) == ranges)
    }

    @Test("A selection inside one cell is left alone")
    func withinOneCellDoesNotSnap() {
        let editor = loadEditor("Intro.\n\n| c1 | c2 |\n| --- | --- |\n| alpha | b |\n")
        let ns = editor.rawSource as NSString
        let range = NSRange(location: ns.range(of: "alpha").location, length: 3)
        editor.setSelectedRange(range)
        #expect(editor.selectedRange() == range)
        #expect(editor.tableCellSelection == nil)
        #expect(editor.tableCellSelectionBox() == nil)
    }

    /// The box is the hull of the cells, and it stays inside the table — the
    /// bug it replaces was a highlight running to the text container's edge.
    @Test("The selection box is the hull of the selected cells")
    func selectionBoxIsTheHull() {
        let editor = loadEditor(doc)
        let ns = editor.rawSource as NSString
        let from = ns.range(of: "a").location
        let to = ns.range(of: "d").location + 1
        editor.setSelectedRange(NSRange(location: from, length: to - from))

        guard let grid = editor.tableGrid(blockIndex: tableIndex(editor)),
              let box = editor.tableCellSelectionBox(),
              let topLeft = grid.cellRect(row: 2, column: 0),
              let bottomRight = grid.cellRect(row: 3, column: 1) else {
            Issue.record("no box")
            return
        }
        #expect(abs(box.minX - topLeft.minX) < 0.5)
        #expect(abs(box.maxX - bottomRight.maxX) < 0.5)
        #expect(abs(box.minY - topLeft.minY) < 0.5)
        #expect(abs(box.maxY - bottomRight.maxY) < 0.5)
        // Inside the table, not out at the container edge.
        #expect(box.maxX <= grid.columnEdges.last! + 0.5)
    }

    /// The dots drag the box wider by holding the opposite corner, so a grab on
    /// the bottom-right one has to anchor on the top-left cell.
    @Test("A dot grab anchors on the opposite corner")
    func dotGrabAnchorsOnTheOppositeCorner() {
        let editor = loadEditor(doc)
        let ns = editor.rawSource as NSString
        let from = ns.range(of: "a").location
        let to = ns.range(of: "b").location + 1
        editor.setSelectedRange(NSRange(location: from, length: to - from))
        guard let box = editor.tableCellSelectionBox() else {
            Issue.record("no box")
            return
        }
        let grab = editor.tableCellSelectionAnchor(at: NSPoint(x: box.maxX, y: box.maxY))
        #expect(grab?.anchor.row == 2)
        #expect(grab?.anchor.column == 0)
        // Nowhere near a dot.
        #expect(editor.tableCellSelectionAnchor(at: NSPoint(x: box.midX, y: box.midY)) == nil)
    }

    /// Extending to a further cell must not stop at the separator row, which
    /// holds no text and is never a selectable corner.
    @Test("Extending across the header skips the separator row")
    func extendingSkipsTheSeparator() {
        let editor = loadEditor(doc)
        editor.selectTableCells(blockIndex: tableIndex(editor), from: (0, 0), to: (3, 1))
        guard let block = editor.tableCellSelection else {
            Issue.record("no selection")
            return
        }
        #expect(block.rows == 0...3)
        #expect(block.columns == 0...1)
        guard let grid = editor.tableGrid(blockIndex: tableIndex(editor)) else { return }
        // A point on the separator resolves to a real row either side of it.
        let onSeparator = NSPoint(x: grid.columnEdges[0] + 1, y: grid.rows[1].midY + 1)
        #expect(editor.tableCellPosition(at: onSeparator,
                                         blockIndex: tableIndex(editor))?.row == 2)
    }

    /// A right-click used to select the cell's text. It no longer does: moving
    /// the selection under a menu the user only meant to open is a surprise.
    @Test("A cell's context menu leaves the selection alone")
    func contextMenuDoesNotSelectTheCell() {
        let editor = loadEditor(doc)
        caret(editor, to: "a")
        let before = editor.selectedRange()
        let menu = NSMenu()
        editor.addTableItems(to: menu, blockIndex: tableIndex(editor), row: 2, column: 0, axis: nil)
        #expect(editor.selectedRange() == before)
        #expect(editor.tableCellSelectionBox() == nil)
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
