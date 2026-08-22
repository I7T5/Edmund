import AppKit

// MARK: - A rendered table's on-screen grid
//
// The renderer splits a table into rows and columns on every restyle and throws
// the split away — but not quite all of it. Every row's paragraph keeps a
// `.tableRow` BlockDecoration holding the column border offsets, the table's
// full width and the text's inset from its left edge, because the fragment has
// to draw the borders from them. Those are exactly the numbers the row and
// column handles need, so the grid is *read back* here rather than measured
// again, and the handles can never disagree with the borders the reader sees.
//
// Contrast `tableCellRect(for:)`, which unions a cell's text segments: that is
// approximate at the column edges (TextKit 2 splits a kern gap between the
// segments either side of it) and useless for an overflowing cell, whose real
// characters are hidden. The decoration is exact for both.

/// A table's on-screen grid, in view coordinates.
struct TableGrid {
    /// One rect per table row, in line order — including the separator row,
    /// which renders as a 4pt strip. Full row boxes: the vertical padding and a
    /// wrapped cell's extra height are inside them.
    let rows: [NSRect]
    /// The table's left edge, each internal column border, and its right edge.
    /// Count is one more than the number of columns.
    let columnEdges: [CGFloat]

    var columns: Int { max(0, columnEdges.count - 1) }

    /// The box of one cell — the column's x-range across the row's height.
    func cellRect(row: Int, column: Int) -> NSRect? {
        guard rows.indices.contains(row), column >= 0, column < columns else { return nil }
        let box = rows[row]
        return NSRect(x: columnEdges[column], y: box.minY,
                      width: columnEdges[column + 1] - columnEdges[column], height: box.height)
    }

    /// The whole table's box.
    var bounds: NSRect? {
        guard let first = rows.first, let last = rows.last,
              let left = columnEdges.first, let right = columnEdges.last else { return nil }
        return NSRect(x: left, y: first.minY, width: right - left, height: last.maxY - first.minY)
    }
}

extension EditorTextView {

    /// The grid of the table at `blockIndex`, or nil when there isn't one to
    /// draw against: a non-table block, a table showing its raw markdown (the
    /// pipes are visible, there is no grid), or one that isn't laid out yet.
    func tableGrid(blockIndex: Int) -> TableGrid? {
        guard blockIndex < blocks.count, blocks[blockIndex].kind == .table,
              !(rawTableEditing && activeBlockIndexForRawTable() == blockIndex),
              let tlm = textLayoutManager,
              let range = blockTextRange(blocks[blockIndex].range, tlm) else { return nil }

        // One layout fragment per row: a table row is one paragraph, which is
        // what lets the per-row strokes line up into continuous borders.
        let origin = textContainerOrigin
        var rows: [NSRect] = []
        var textOriginX: CGFloat?
        tlm.enumerateTextLayoutFragments(from: range.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(range.endLocation)
                    == .orderedAscending else { return false }
            let frame = fragment.layoutFragmentFrame
            if textOriginX == nil { textOriginX = frame.minX }
            rows.append(frame.offsetBy(dx: origin.x, dy: origin.y))
            return true
        }
        guard !rows.isEmpty, let textOriginX else { return nil }

        // The decoration's offsets are relative to the row's *text* start, which
        // is the fragment's own minX (the frame hugs the laid-out text). Every
        // row carries the same ones; the header's will do.
        guard let storage = textStorage,
              blocks[blockIndex].range.location < storage.length,
              let decoration = storage.attribute(.blockDecoration,
                                                 at: blocks[blockIndex].range.location,
                                                 effectiveRange: nil) as? BlockDecoration,
              case .tableRow(let xOffsets, let width, let leftInset, _, _, let topInset)
                = decoration.kind
        else { return nil }

        // The header row's fragment starts above the table: it reserves the
        // band the column handle sits in, which the borders skip. The grid is
        // what the reader sees, so that band is not part of row 0.
        rows[0] = NSRect(x: rows[0].minX, y: rows[0].minY + topInset,
                         width: rows[0].width, height: rows[0].height - topInset)

        let left = textOriginX + origin.x - leftInset
        return TableGrid(rows: rows,
                         columnEdges: [left] + xOffsets.map { textOriginX + origin.x + $0 }
                             + [left + width])
    }
}
