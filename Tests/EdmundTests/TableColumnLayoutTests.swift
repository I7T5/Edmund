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

    /// AppKit stops sending `selectionDidChange` while a click or drag is still
    /// in flight, so the wrapped-cell caret upkeep that rides it did not run
    /// during a mouse-button hold — AppKit's own caret stayed drawn on the
    /// cell's hidden characters (top-left) until release, then jumped to the
    /// real position. The upkeep runs from `setSelectedRanges` on a
    /// still-selecting install now; the proxy for "AppKit's caret is drawn" is
    /// `insertionPointColor` not being clear.
    @Test("A still-selecting install into a wrapped cell suppresses AppKit's caret")
    func stillSelectingKeepsTheWrappedCaretHonest() throws {
        let editor = loadEditor(Self.truthTable)
        let index = try #require(editor.blocks.firstIndex(where: { $0.kind == .table }))
        let cell = try #require(editor.tableCell(blockIndex: index, row: 0, column: 6))
        let inWrapped = editor.tableCellTextRange(cell).location

        func ipcIsClear() -> Bool {
            (editor.insertionPointColor?.usingColorSpace(.sRGB)?.alphaComponent ?? 1) < 0.01
        }

        // Caret in the prose above the table: AppKit draws its own caret.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!ipcIsClear())

        // A still-selecting install into the wrapped cell — the state a real
        // click produces while the button is held — must already suppress it.
        editor.setSelectedRanges([NSValue(range: NSRange(location: inWrapped, length: 0))],
                                 affinity: .downstream, stillSelecting: true)
        #expect(ipcIsClear(), "AppKit's caret was left drawn during the hold")
    }

    /// A click in a wrapped cell's blank space below the text lands the caret
    /// at the end of the cell's text — wherever along that blank strip it fell.
    /// This is what an unwrapped cell already does; the two were inconsistent,
    /// with a wrapped cell instead taking the character sitting above the click.
    @Test("A click below a wrapped cell's text goes to the text end")
    func clickBelowWrappedTextGoesToEnd() throws {
        let editor = loadEditor(Self.truthTable)
        guard let tlm = editor.textLayoutManager,
              let index = editor.blocks.firstIndex(where: { $0.kind == .table }),
              let grid = editor.tableGrid(blockIndex: index),
              // column 6 header "(not A) or (not B)" wraps to several lines
              let cell = editor.tableCell(blockIndex: index, row: 0, column: 6),
              let box = grid.cellRect(row: 0, column: 6),
              let location = tlm.location(tlm.documentRange.location,
                                          offsetBy: cell.contentRange.location),
              let fragment = tlm.textLayoutFragment(for: location) as? DecoratedTextLayoutFragment,
              let paragraph = fragment.textElement?.elementRange?.location else {
            Issue.record("no wrapped cell")
            return
        }
        let base = tlm.offset(from: tlm.documentRange.location, to: paragraph)
        let text = editor.tableCellTextRange(cell)
        let textEnd = text.upperBound
        let origin = editor.textContainerOrigin
        let frame = fragment.layoutFragmentFrame
        // The x-band the drawn text actually occupies (a click outside it, in
        // the cell's side padding, is handled by the grid snap, not this path).
        let firstLine = try #require(
            editor.wrappedCellRects(for: NSRange(location: text.location, length: 0)).first)
        let bandLeft = firstLine.minX
        let bandRight = box.maxX - (box.maxX - bandLeft) * 0.15
        // Along the bottom blank strip, within the text band: left, middle,
        // right. Each must land at the end of the text, not the char above.
        let y = box.maxY - 2
        for x in [bandLeft + 2, (bandLeft + bandRight) / 2, bandRight] {
            let local = CGPoint(x: x - origin.x - frame.minX, y: y - origin.y - frame.minY)
            let hit = fragment.cellWrapCharacterIndex(for: local).map { base + $0 }
            #expect(hit == textEnd, "click at x=\(Int(x)) landed at \(hit ?? -1), not \(textEnd)")
        }
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

    /// A ten-column truth table: narrow columns, every header cell wrapped, the
    /// data cells not. Everything below was measured against this one table.
    private static let truthTable = """
        Intro.

        | A | B | not A | not B | not(A and B) | not(A or B) | (not A) or (not B) | A or (not B) | (not B) or B | (not B) and B |
        | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        | T | T | F | F | F | F | F | T | T | F |
        | T | F | F | T | T | F | T | T | T | F |
        | F | T | T | F | T | F | T | F | T | F |
        | F | F | T | T | T | T | T | T | T | F |

        """

    /// The row's paragraph is indented by the cell pad so the left border can
    /// stand outside the text, and that indent has to come out of the width
    /// budget. When it did not, the row's advance exactly filled the line and
    /// the closing pipe wrapped — dragging the last cell's text down under the
    /// first cell once the window was a little narrower.
    @Test("A row's text never wraps onto a second line")
    func rowTextStaysOnOneLine() {
        let editor = loadEditor(Self.truthTable)
        guard let tlm = editor.textLayoutManager,
              let index = editor.blocks.firstIndex(where: { $0.kind == .table }),
              let range = editor.blockTextRange(editor.blocks[index].range, tlm) else {
            Issue.record("no table")
            return
        }
        var row = 0
        tlm.enumerateTextLayoutFragments(from: range.location, options: [.ensuresLayout]) { fragment in
            guard fragment.rangeInElement.location.compare(range.endLocation) == .orderedAscending
            else { return false }
            // The last row also absorbs the document's trailing empty line,
            // which is a second fragment of its own and not a wrap.
            let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
            #expect(lines.count == 1, "row \(row) laid out on \(lines.count) lines")
            row += 1
            return true
        }
        #expect(row == 6)
    }

    /// The padding is not content and does not go into a wrapped cell's scratch
    /// layout: in a narrow column a leading space could take the first line by
    /// itself, and that cell's text then started a line lower than the cells
    /// beside it.
    @Test("Wrapped and unwrapped header cells start on the same line")
    func headerCellsShareATop() {
        let editor = loadEditor(Self.truthTable)
        guard let tlm = editor.textLayoutManager,
              let index = editor.blocks.firstIndex(where: { $0.kind == .table }),
              let grid = editor.tableGrid(blockIndex: index) else {
            Issue.record("no grid")
            return
        }
        var tops: [CGFloat] = []
        for column in 0..<grid.columns {
            guard let cell = editor.tableCell(blockIndex: index, row: 0, column: column) else { continue }
            let text = editor.tableCellTextRange(cell)
            if let wrapped = editor.wrappedCellRects(for: NSRange(location: text.location,
                                                                  length: 0)).first {
                tops.append(wrapped.minY)
            } else if let from = tlm.location(tlm.documentRange.location, offsetBy: text.location),
                      let to = tlm.location(tlm.documentRange.location, offsetBy: text.upperBound),
                      let range = NSTextRange(location: from, end: to) {
                let origin = editor.textContainerOrigin
                tlm.enumerateTextSegments(in: range, type: .standard, options: []) { _, f, _, _ in
                    tops.append(f.minY + origin.y); return false
                }
            }
        }
        #expect(tops.count == grid.columns)
        if let first = tops.first {
            for top in tops { #expect(abs(top - first) < 1, "a header cell starts \(top - first)pt off") }
        }
    }

    /// `NSTextLineFragment.characterIndex(for:)` names the character under the
    /// point; a click puts the caret at the nearer edge of it. Without the
    /// midpoint rule every click on the right half of a letter in a wrapped
    /// cell landed one character early.
    @Test("A click in a wrapped cell rounds at the glyph's midpoint")
    func wrappedCellClickRoundsAtTheMidpoint() {
        let editor = loadEditor(Self.truthTable)
        guard let tlm = editor.textLayoutManager,
              let index = editor.blocks.firstIndex(where: { $0.kind == .table }),
              let cell = editor.tableCell(blockIndex: index, row: 0, column: 4) else {
            Issue.record("no cell")
            return
        }
        let text = editor.tableCellTextRange(cell)
        for k in 0..<3 {
            let offset = text.location + k
            guard let glyph = editor.wrappedCellRects(for: NSRange(location: offset, length: 1)).first,
                  let location = tlm.location(tlm.documentRange.location, offsetBy: offset),
                  let fragment = tlm.textLayoutFragment(for: location) as? DecoratedTextLayoutFragment,
                  let paragraph = fragment.textElement?.elementRange?.location else {
                Issue.record("no glyph at \(k)")
                continue
            }
            let base = tlm.offset(from: tlm.documentRange.location, to: paragraph)
            let origin = editor.textContainerOrigin
            let frame = fragment.layoutFragmentFrame
            func hit(_ x: CGFloat) -> Int? {
                fragment.cellWrapCharacterIndex(for: CGPoint(x: x - origin.x - frame.minX,
                                                             y: glyph.midY - origin.y - frame.minY))
                    .map { base + $0 }
            }
            #expect(hit(glyph.minX + 1) == offset)        // left half: before it
            #expect(hit(glyph.maxX - 1) == offset + 1)    // right half: after it
        }
    }
}
