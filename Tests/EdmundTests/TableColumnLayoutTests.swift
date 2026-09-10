import Testing
import AppKit
@testable import EdmundCore

/// A table has to fit the reading column, whatever is in it. Columns are
/// clamped to their share of the available width and a cell too wide for its
/// clamped column is redrawn wrapped — so content that does not fit makes the
/// row taller, never the table wider.

@Suite("Table column layout")
@MainActor
struct TableColumnLayoutTests {

    private func loadEditor(_ text: String) -> EditorTextView {
        let editor = makeEditor()
        editor.updateContentInset()
        editor.loadContent(text)
        ensureFullLayout(editor)
        layOutViewport(editor)
        return editor
    }

    private func table(columns: Int, cell: String) -> String {
        let header = (0..<columns).map { "h\($0)" }.joined(separator: " | ")
        let rule = (0..<columns).map { _ in "---" }.joined(separator: " | ")
        let row = (0..<columns).map { _ in cell }.joined(separator: " | ")
        return "Intro.\n\n| \(header) |\n| \(rule) |\n| \(row) |\n"
    }

    private func grid(_ editor: EditorTextView) -> TableGrid? {
        guard let index = editor.blocks.firstIndex(where: { $0.kind == .table }) else { return nil }
        return editor.tableGrid(blockIndex: index)
    }

    /// The regression: the per-column minimum was a hard floor, so past a
    /// certain column count the table demanded more width than the row had and
    /// simply hung off the edge. The floor gives way to the share now — narrow
    /// columns wrap, an overhang does not.
    @Test("A table fits the content width however many columns it has")
    func tableNeverOutgrowsTheColumn() {
        let long = String(repeating: "verylongword ", count: 12)
        for columns in [2, 3, 6, 10, 14] {
            let editor = loadEditor(table(columns: columns, cell: long))
            guard let grid = grid(editor), let bounds = grid.bounds else {
                Issue.record("no grid at \(columns) columns")
                continue
            }
            let container = editor.textContainer?.size.width ?? 0
            #expect(bounds.width <= container,
                    "\(columns) columns ran to \(bounds.width) in a \(container) column")
        }
    }

    /// Content that does not fit makes the row taller. Not an incidental
    /// consequence — it is the whole mechanism by which the table stays inside
    /// the reading column.
    @Test("Content too wide for its column makes the row taller")
    func overlongContentGrowsTheRow() {
        let short = loadEditor(table(columns: 3, cell: "x"))
        let long = loadEditor(table(columns: 3, cell: String(repeating: "long ", count: 30)))
        guard let plain = grid(short), let wrapped = grid(long) else {
            Issue.record("no grid")
            return
        }
        #expect(wrapped.rows[2].height > plain.rows[2].height * 2)
    }

    /// A row whose cells *all* overflow has no visible characters left to give
    /// its line any height, and the row used to collapse onto its own padding —
    /// a header of long labels ended up shorter than the body beneath it.
    @Test("A row of all-overflowing cells keeps its height")
    func fullyWrappedRowKeepsItsHeight() {
        let plainHeader = loadEditor(table(columns: 10, cell: "x"))
        let wrappedHeader = loadEditor(table(columns: 10,
                                             cell: String(repeating: "long ", count: 8)))
        guard let plain = grid(plainHeader), let wrapped = grid(wrappedHeader) else {
            Issue.record("no grid")
            return
        }
        // Same header text either side; only the body forces the columns narrow
        // enough for the header labels to wrap too.
        #expect(wrapped.rows[0].height >= plain.rows[0].height - 0.5,
                "the header collapsed against the plain one")
    }

    /// Cell contents are inset from the border they sit against, rather than
    /// touching it.
    @Test("Cell text is inset from its column border")
    func cellTextIsInsetFromTheBorder() {
        let editor = loadEditor("Intro.\n\n| heading | b |\n| --- | --- |\n| content | d |\n")
        guard let grid = grid(editor),
              let index = editor.blocks.firstIndex(where: { $0.kind == .table }),
              let cell = editor.tableCell(blockIndex: index, row: 2, column: 0),
              let tlm = editor.textLayoutManager else {
            Issue.record("no grid")
            return
        }
        let text = editor.tableCellTextRange(cell)
        guard let from = tlm.location(tlm.documentRange.location, offsetBy: text.location),
              let to = tlm.location(tlm.documentRange.location, offsetBy: text.upperBound),
              let range = NSTextRange(location: from, end: to) else {
            Issue.record("no range")
            return
        }
        let origin = editor.textContainerOrigin
        var box: NSRect?
        tlm.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
            let rect = frame.offsetBy(dx: origin.x, dy: origin.y)
            box = box.map { $0.union(rect) } ?? rect
            return true
        }
        guard let box else {
            Issue.record("no segments")
            return
        }
        #expect(box.minX - grid.columnEdges[0] >= 4,
                "text starts \(box.minX - grid.columnEdges[0])pt from the border")
    }
}
