import AppKit

// MARK: - Table Rendering Support
//
// Helpers used by the `.table` branch of `styleBlock` (in
// EditorTextView+Rendering.swift) to lay out and draw GFM tables:
//
//   - `TableRowTextBlock` draws the column/row border lines behind each row.
//   - `splitTableRow` / `cellRanges` parse a pipe-delimited row into its cells.
//
// A rendered table is a run of consecutive single-line paragraphs (one per
// table row) that the BlockParser merges into a single block. Each row's
// paragraph style carries a `TableRowTextBlock`; because every row uses the
// same column X offsets, the per-row vertical strokes line up into continuous
// column borders.

/// `NSTextBlock` subclass for table rows. Each row draws vertical border lines
/// at column boundaries. The separator row also draws a horizontal hairline.
/// All rows use the same column offsets so the vertical lines align into
/// continuous column borders.
final class TableRowTextBlock: NSTextBlock {

    /// X offsets (from content area left edge) where vertical border lines are drawn.
    var verticalLineXOffsets: [CGFloat] = []

    /// Offset from frameRect.minX to the content area (= left padding).
    var contentLeftOffset: CGFloat = 0

    /// Whether to draw a horizontal hairline centered in the row (separator).
    var drawHorizontalLine = false

    /// Height override for the separator row (collapses to thin strip).
    var heightOverride: CGFloat?

    override func rectForLayout(
        at startingPosition: CGPoint,
        in rect: NSRect,
        textContainer: NSTextContainer,
        characterRange charRange: NSRange
    ) -> NSRect {
        var r = super.rectForLayout(at: startingPosition, in: rect,
                                    textContainer: textContainer,
                                    characterRange: charRange)
        if let h = heightOverride {
            r.size.height = h
        }
        return r
    }

    override func drawBackground(
        withFrame frameRect: NSRect,
        in controlView: NSView,
        characterRange charRange: NSRange,
        layoutManager: NSLayoutManager
    ) {
        NSColor.separatorColor.setStroke()
        let baseX = frameRect.minX + contentLeftOffset

        // Vertical borders at column boundaries
        for xOffset in verticalLineXOffsets {
            let path = NSBezierPath()
            let x = round(baseX + xOffset) + 0.5
            path.move(to: NSPoint(x: x, y: frameRect.minY))
            path.line(to: NSPoint(x: x, y: frameRect.maxY))
            path.lineWidth = 1
            path.stroke()
        }

        // Horizontal separator
        if drawHorizontalLine {
            let path = NSBezierPath()
            let y = round(frameRect.midY) + 0.5
            path.move(to: NSPoint(x: frameRect.minX, y: y))
            path.line(to: NSPoint(x: frameRect.maxX, y: y))
            path.lineWidth = 1
            path.stroke()
        }
    }
}

// MARK: - Table Row Parsing

/// Splits a markdown table row into cell strings (text between pipes).
/// Handles both `| A | B |` (outer pipes) and `A | B` (no outer pipes).
func splitTableRow(_ line: String) -> [String] {
    var parts = line.components(separatedBy: "|")
    // Remove empty/whitespace-only first/last from outer pipes.
    if let first = parts.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
        parts.removeFirst()
    }
    if let last = parts.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        parts.removeLast()
    }
    return parts
}

/// Returns `(start, end)` character ranges for each cell in a table line.
/// Works with or without outer pipes. `start` is the first content char,
/// `end` is one past the last content char (i.e., the next pipe or line end).
func cellRanges(in line: NSString) -> [(start: Int, end: Int)] {
    var pipePos: [Int] = []
    for ci in 0..<line.length {
        if line.character(at: ci) == 0x7C { pipePos.append(ci) }
    }
    guard !pipePos.isEmpty else { return [] }

    // Build edge list: either the pipe position or a virtual -1/length sentinel.
    var edges: [Int] = []
    if pipePos[0] == 0 {
        edges.append(contentsOf: pipePos)
    } else {
        edges.append(-1)
        edges.append(contentsOf: pipePos)
    }
    if pipePos.last != line.length - 1 {
        edges.append(line.length)
    }

    var result: [(start: Int, end: Int)] = []
    for ei in 0..<(edges.count - 1) {
        let s = edges[ei] + 1
        let e = edges[ei + 1]
        if e > s { result.append((s, e)) }
    }
    return result
}
