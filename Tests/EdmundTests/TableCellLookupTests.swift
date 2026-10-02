import Testing
import AppKit
@testable import EdmundCore

/// Finding a table cell by row and column, which the structural edits, copy
/// and inline editing rely on after the table's ranges have moved.

@Suite("Table cell lookup")
@MainActor
struct TableCellLookupTests {

    private let table = "| a | bb | ccc |\n|---|---|---|\n| x | yy | zzz |"

    private func loadEditor(_ text: String) -> EditorTextView {
        let editor = makeEditor()
        editor.updateContentInset()
        editor.loadContent(text)
        ensureFullLayout(editor)
        layOutViewport(editor)
        return editor
    }

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

    /// The reason the lookup is by position at all: an edit that changes a
    /// cell's length invalidates every range after it in the row, so the next
    /// cell cannot be named by the offsets that were valid a moment ago.
    @Test("Lookup survives an edit that shifts the row's ranges")
    func lookupSurvivesAShiftingEdit() {
        let editor = loadEditor(table)
        guard let blockIndex = editor.blocks.firstIndex(where: { $0.kind == .table }),
              let first = editor.tableCell(blockIndex: blockIndex, row: 2, column: 0),
              let staleSecond = editor.tableCell(blockIndex: blockIndex, row: 2, column: 1) else {
            Issue.record("no cells")
            return
        }
        editor.applyFormattingEdit(rawRange: first.contentRange, replacement: " a much longer value ",
                                   select: NSRange(location: first.contentRange.location, length: 0))

        guard let freshSecond = editor.tableCell(blockIndex: blockIndex, row: 2, column: 1) else {
            Issue.record("second cell lost after the edit")
            return
        }
        #expect(freshSecond.contentRange.location != staleSecond.contentRange.location)
        #expect((editor.rawSource as NSString).substring(with: freshSecond.contentRange) == " yy ")
    }
}
