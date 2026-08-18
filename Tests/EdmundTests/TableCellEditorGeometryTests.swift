import Testing
import AppKit
@testable import EdmundCore

/// The popup takes the table's width and keeps it from cell to cell, so moving
/// along a row slides only the arrow. These cover the geometry and the
/// by-position cell lookup that the move depends on; the popover itself needs a
/// window, so it isn't built here.

@Suite("Table cell editor geometry")
@MainActor
struct TableCellEditorGeometryTests {

    private let table = "| a | bb | ccc |\n|---|---|---|\n| x | yy | zzz |"

    private func loadEditor(_ text: String) -> EditorTextView {
        let editor = makeEditor()
        editor.updateContentInset()
        editor.loadContent(text)
        ensureFullLayout(editor)
        layOutViewport(editor)
        return editor
    }

    @Test("The popup is as wide as the table")
    func widthMatchesTheTable() {
        let editor = loadEditor("lead\n\n\(table)\n")
        guard let blockIndex = editor.blocks.firstIndex(where: { $0.kind == .table }),
              let rect = editor.tableRect(blockIndex: blockIndex) else {
            Issue.record("no table rect")
            return
        }
        #expect(rect.width > 0)
        #expect(editor.cellEditorWidth(blockIndex: blockIndex)
            == max(EditorTextView.cellEditorMinWidth, rect.width))
    }

    /// The width is a property of the table, not of the cell — that is what
    /// keeps the field still while the arrow travels.
    @Test("Every cell in a table yields the same popup width")
    func widthIsConstantAcrossCells() {
        let editor = loadEditor(table)
        guard let blockIndex = editor.blocks.firstIndex(where: { $0.kind == .table }) else {
            Issue.record("no table")
            return
        }
        let widths = (0..<3).map { _ in editor.cellEditorWidth(blockIndex: blockIndex) }
        #expect(Set(widths).count == 1)
    }

    @Test("Cells in one row have different anchor rects")
    func anchorsDifferPerColumn() {
        let editor = loadEditor(table)
        guard let blockIndex = editor.blocks.firstIndex(where: { $0.kind == .table }),
              let first = editor.tableCell(blockIndex: blockIndex, row: 0, column: 0),
              let second = editor.tableCell(blockIndex: blockIndex, row: 0, column: 1),
              let a = editor.tableCellRect(for: first),
              let b = editor.tableCellRect(for: second) else {
            Issue.record("no rects")
            return
        }
        #expect(a.minX < b.minX)          // the arrow has somewhere to travel to
        #expect(abs(a.midY - b.midY) < 1) // same row, so it travels sideways only
    }

    // MARK: - The travelling arrow

    /// The card spans the table and holds still; the arrow is the only thing
    /// that moves. So the arrow's offset must grow with the column while the
    /// card's width stays put.
    @Test("The arrow tracks the column across a row")
    func arrowTracksTheColumn() {
        let editor = loadEditor(table)
        guard let b = editor.blocks.firstIndex(where: { $0.kind == .table }) else {
            Issue.record("no table")
            return
        }
        let xs = (0..<3).compactMap { col -> CGFloat? in
            guard let cell = editor.tableCell(blockIndex: b, row: 0, column: col) else { return nil }
            return editor.cellEditorArrowX(for: cell)
        }
        #expect(xs.count == 3)
        #expect(xs == xs.sorted())
        #expect(Set(xs).count == 3)
    }

    @Test("The arrow stays inside the card")
    func arrowWithinTheCard() {
        let editor = loadEditor(table)
        guard let b = editor.blocks.firstIndex(where: { $0.kind == .table }),
              let width = editor.tableRect(blockIndex: b)?.width else {
            Issue.record("no table")
            return
        }
        for col in 0..<3 {
            guard let cell = editor.tableCell(blockIndex: b, row: 0, column: col),
                  let x = editor.cellEditorArrowX(for: cell) else {
                Issue.record("no arrow for column \(col)")
                continue
            }
            #expect(x >= 0)
            #expect(x <= width)
        }
    }

    /// A commit can redistribute the columns, which changes the table's width —
    /// the card has to follow it rather than keep the width it opened with.
    @Test("The card's width follows the table's")
    func widthFollowsTheTable() {
        let editor = loadEditor("| a | b |\n|---|---|\n| x | y |")
        guard let b = editor.blocks.firstIndex(where: { $0.kind == .table }),
              let cell = editor.tableCell(blockIndex: b, row: 2, column: 0) else {
            Issue.record("no table")
            return
        }
        let before = editor.cellEditorWidth(blockIndex: b)
        editor.commitTableCell(cell, text: String(repeating: "wide ", count: 12))
        ensureFullLayout(editor)
        let after = editor.cellEditorWidth(blockIndex: b)
        #expect(after > before)
    }

    // MARK: - By-position lookup

    @Test("A cell can be found by row and column")
    func lookupByPosition() {
        let editor = loadEditor(table)
        guard let blockIndex = editor.blocks.firstIndex(where: { $0.kind == .table }),
              let cell = editor.tableCell(blockIndex: blockIndex, row: 2, column: 2) else {
            Issue.record("no cell")
            return
        }
        #expect((editor.rawSource as NSString).substring(with: cell.contentRange) == " zzz ")
    }

    @Test("The separator row and out-of-range positions find nothing")
    func lookupRejectsBadPositions() {
        let editor = loadEditor(table)
        guard let b = editor.blocks.firstIndex(where: { $0.kind == .table }) else { return }
        #expect(editor.tableCell(blockIndex: b, row: 1, column: 0) == nil)
        #expect(editor.tableCell(blockIndex: b, row: 0, column: 9) == nil)
        #expect(editor.tableCell(blockIndex: b, row: 9, column: 0) == nil)
        #expect(editor.tableCell(blockIndex: b, row: 0, column: -1) == nil)
    }

    /// The reason the lookup is by position at all: a commit that changes a
    /// cell's length invalidates every range after it in the row, so the next
    /// cell cannot be named by the offsets that were valid a moment ago.
    @Test("Lookup survives a commit that shifts the row's ranges")
    func lookupSurvivesAShiftingCommit() {
        let editor = loadEditor(table)
        guard let blockIndex = editor.blocks.firstIndex(where: { $0.kind == .table }),
              let first = editor.tableCell(blockIndex: blockIndex, row: 2, column: 0),
              let staleSecond = editor.tableCell(blockIndex: blockIndex, row: 2, column: 1) else {
            Issue.record("no cells")
            return
        }
        editor.commitTableCell(first, text: "a much longer value")

        guard let freshSecond = editor.tableCell(blockIndex: blockIndex, row: 2, column: 1) else {
            Issue.record("second cell lost after commit")
            return
        }
        #expect(freshSecond.contentRange.location != staleSecond.contentRange.location)
        #expect((editor.rawSource as NSString).substring(with: freshSecond.contentRange) == " yy ")
    }
}
