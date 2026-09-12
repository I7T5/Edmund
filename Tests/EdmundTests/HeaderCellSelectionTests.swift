import Testing
import AppKit
@testable import EdmundCore

/// A text selection inside a header cell must survive the table's selection
/// handling — it must not be turned into a whole-cell block (that path is only
/// for selections crossing cells) nor snapped away, so header text can be
/// drag-selected the same as any body cell's.

@Suite("Header cell selection")
@MainActor
struct HeaderCellSelectionTests {
    private func loadEditor(_ text: String) -> EditorTextView {
        let editor = makeEditor()
        editor.updateContentInset()
        editor.loadContent(text)
        ensureFullLayout(editor)
        layOutViewport(editor)
        return editor
    }

    @Test("A partial selection in a header cell is kept as text")
    func headerTextSelectionSurvives() {
        let editor = loadEditor("| Header One | b |\n| --- | --- |\n| c | d |\n")
        let ns = editor.rawSource as NSString
        let needle = ns.range(of: "eader On")   // interior of the header cell's text
        editor.setSelectedRange(needle)
        // Kept verbatim: not widened to the whole cell, not collapsed.
        #expect(editor.selectedRange() == needle)
        // And it is a text selection, not a cell block.
        #expect(editor.tableCellSelection == nil)
    }

    /// A drag ending back inside the same header cell (tableClickPoint set, the
    /// way mouseDown leaves it) still resolves to a text selection, not a block.
    @Test("A same-cell header drag stays a text selection")
    func headerDragStaysText() {
        let editor = loadEditor("| Header One | b |\n| --- | --- |\n| c | d |\n")
        guard let ti = editor.blocks.firstIndex(where: { $0.kind == .table }),
              let grid = editor.tableGrid(blockIndex: ti),
              let cellRect = grid.cellRect(row: 0, column: 0) else {
            Issue.record("no grid")
            return
        }
        // Anchor a "drag" inside the header cell, as mouseDown would.
        editor.tableClickPoint = NSPoint(x: cellRect.minX + 4, y: cellRect.midY)
        defer { editor.tableClickPoint = nil }
        let ns = editor.rawSource as NSString
        let needle = ns.range(of: "eader On")
        editor.setSelectedRanges([NSValue(range: needle)], affinity: .downstream,
                                 stillSelecting: true)
        #expect(editor.selectedRange().length > 0, "the header drag selected nothing")
        #expect(editor.tableCellSelection == nil, "a same-cell drag became a cell block")
    }
}
