import AppKit

// MARK: - Table Rendering Support
//
// Helpers used by the `.table` branch of `styleBlock` (in
// EditorTextView+Rendering.swift) to lay out GFM tables:
// `splitTableRow` / `cellRanges` parse a pipe-delimited row into its cells.
//
// A rendered table is a run of consecutive single-line paragraphs (one per
// table row) that the BlockParser merges into a single block. Each row
// carries a `.tableRow` BlockDecoration; because every row uses the same
// column X offsets, the per-row vertical strokes line up into continuous
// column borders. A cell too wide for its column renders across multiple
// *visual* sublines within that one paragraph, via `.tableCellWraps`
// (EditorTextView+TextKit2.swift) — the paragraph/row count is unchanged.

// MARK: - Column Width Distribution

/// Clamps each column's natural (widest-cell) width to fit `available` total
/// width, so one very wide cell doesn't stretch the whole table off screen.
/// Columns already at or under their fair share (`available / count`) keep
/// their natural width; the slack they don't use is handed to the columns
/// that exceed fair share, split evenly among them and floored at `minWidth`.
/// ponytail: single-pass, not CSS's iterative auto-table-layout fixed point —
/// revisit only if real documents show pathological many-column cases.
func distributeColumnWidths(natural: [CGFloat], available: CGFloat,
                            minWidth: CGFloat) -> [CGFloat] {
    let numCols = natural.count
    guard numCols > 0, available > 0 else { return natural }
    let fairShare = available / CGFloat(numCols)
    var overIdx: [Int] = []
    var usedByUnderShare: CGFloat = 0
    for (ci, width) in natural.enumerated() {
        if width <= fairShare { usedByUnderShare += width } else { overIdx.append(ci) }
    }
    guard !overIdx.isEmpty else { return natural }
    let remaining = max(0, available - usedByUnderShare)
    let perOverShare = remaining / CGFloat(overIdx.count)
    // `minWidth` is a preference, not a guarantee. Past a certain column count
    // it cannot be met and still fit — ten columns want ten minimums the row
    // has no room for — and a table that runs off the page is worse than one
    // with narrow columns, because narrow columns wrap and an overhang does
    // not. So the floor gives way to the share when the two disagree.
    let floor = min(minWidth, perOverShare)
    var result = natural
    for ci in overIdx {
        result[ci] = max(floor, min(natural[ci], perOverShare))
    }
    return result
}

// MARK: - Column Alignment

/// GFM table column alignment, parsed from the separator row's `:` markers.
public enum ColumnAlign: Hashable { case left, center, right }

/// Parses per-column alignment from a table's separator row (`:--`/`:-:`/`--:`).
/// `:` on both ends = center, trailing only = right, otherwise left. Padded to
/// `count` with `.left`. Mirrors swift-markdown's `Table.columnAlignments`, so
/// the live editor and the HTML export agree.
func tableColumnAlignments(separatorRow: String, count: Int) -> [ColumnAlign] {
    var aligns = [ColumnAlign](repeating: .left, count: count)
    let cells = splitTableRow(separatorRow)
    for ci in 0..<min(cells.count, count) {
        let t = cells[ci].trimmingCharacters(in: .whitespaces)
        let lead = t.hasPrefix(":")
        let trail = t.hasSuffix(":")
        aligns[ci] = (lead && trail) ? .center : (trail ? .right : .left)
    }
    return aligns
}

// MARK: - Table Row Parsing

/// Splits a markdown table row into cell strings (text between pipes).
/// Handles both `| A | B |` (outer pipes) and `A | B` (no outer pipes).
/// A `\|` is escaped content, not a cell separator (GFM Example 200).
func splitTableRow(_ line: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var prevWasBackslash = false
    for ch in line {
        if ch == "|" && !prevWasBackslash {
            parts.append(current)
            current = ""
        } else {
            current.append(ch)
        }
        prevWasBackslash = (ch == "\\") && !prevWasBackslash
    }
    parts.append(current)

    // Remove empty/whitespace-only first/last from outer pipes.
    if let first = parts.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
        parts.removeFirst()
    }
    if let last = parts.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        parts.removeLast()
    }
    return parts
}

/// A table row rewritten to markdown's conventional skeleton: one leading and
/// one trailing pipe, and exactly one space either side of every pipe.
///
/// Cell *content* is untouched — this fixes the delimiters around it and
/// nothing else, so a table never has its text reflowed, re-wrapped or
/// re-aligned by being tidied. An escaped `\|` is content, not a delimiter
/// (GFM Example 200), on the way in and on the way out.
///
/// Deliberately not `splitTableRow`: that one drops a whitespace-only first or
/// last cell to cope with outer pipes, which would silently delete a genuinely
/// empty leading or trailing cell and change the row's column count. The outer
/// pipes are stripped structurally here — because they are there, not because
/// what they surround looks empty.
func normalizedTableRow(_ line: String) -> String {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.contains("|") else { return line }
    var body = Substring(trimmed)
    if body.hasPrefix("|") { body = body.dropFirst() }
    if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }

    var cells: [String] = []
    var current = ""
    var prevWasBackslash = false
    for ch in body {
        if ch == "|" && !prevWasBackslash {
            cells.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
        } else {
            current.append(ch)
        }
        prevWasBackslash = (ch == "\\") && !prevWasBackslash
    }
    cells.append(current.trimmingCharacters(in: .whitespaces))
    return "| " + cells.joined(separator: " | ") + " |"
}

/// A whole table block rewritten row by row, or nil when every row is already
/// conventional — so a caller can tell "nothing to do" from "no change" without
/// comparing the strings itself, and never files an undo step for a no-op.
func normalizedTableBlock(_ text: String) -> String? {
    var changed = false
    let rows = text.components(separatedBy: "\n").map { line -> String in
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
        let normalized = normalizedTableRow(line)
        if normalized != line { changed = true }
        return normalized
    }
    return changed ? rows.joined(separator: "\n") : nil
}

/// A table reformatted to the canonical aligned ("pretty") form: every column
/// as wide as its widest cell (min 3), cells trailing-padded so the pipes line
/// up, and the separator's dashes filling each column with its alignment colons
/// kept. The column count follows the header, and the header's pipe style
/// (outer pipes or not) is preserved. Unlike `normalizedTableRow` this
/// deliberately reflows the cells — it is for the autofill paths that build a
/// table for the user, not for tidying pasted content.
func prettyAlignedTableLines(_ lines: [String]) -> [String] {
    guard let header = lines.first else { return lines }
    let outer = header.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    let cols = columnSpans(in: header as NSString).count
    guard cols > 0 else { return lines }

    func cells(_ line: String) -> [String] {
        let ns = line as NSString
        return columnSpans(in: ns).map {
            ns.substring(with: NSRange(location: $0.start, length: $0.end - $0.start))
                .trimmingCharacters(in: .whitespaces)
        }
    }
    // Column widths from every row but the separator, floored at three so the
    // separator stays valid GFM.
    var widths = [Int](repeating: 3, count: cols)
    for (i, line) in lines.enumerated() where i != 1 {
        let c = cells(line)
        for col in 0..<min(c.count, cols) { widths[col] = max(widths[col], c[col].count) }
    }
    let markers: [String] = lines.count > 1 ? cells(lines[1]) : []

    func join(_ parts: [String]) -> String {
        let joined = parts.joined(separator: " | ")
        return outer ? "| \(joined) |" : joined
    }
    func bodyRow(_ texts: [String]) -> String {
        join((0..<cols).map { col in
            let t = col < texts.count ? texts[col] : ""
            return t + String(repeating: " ", count: max(0, widths[col] - t.count))
        })
    }
    func separatorRow() -> String {
        join((0..<cols).map { col in
            let m = col < markers.count ? markers[col] : ""
            let lead = m.hasPrefix(":")
            let trail = m.count > 1 && m.hasSuffix(":")
            let dashes = max(1, widths[col] - (lead ? 1 : 0) - (trail ? 1 : 0))
            return (lead ? ":" : "") + String(repeating: "-", count: dashes) + (trail ? ":" : "")
        })
    }
    return lines.enumerated().map { i, line in
        i == 1 ? separatorRow() : bodyRow(cells(line))
    }
}

/// Cell ranges for a table line with *empty* cells kept — `columnSpans` and
/// `cellRanges` differ on `||` alone.
///
/// The renderer drops an empty cell and numbers its columns accordingly, which
/// is self-consistent for drawing. A structural edit cannot afford that: asked
/// to delete column 2 of `| a || b |` it would delete `b`, having never counted
/// the empty one. Everything outside the renderer — `TableCellRef`, the row and
/// column handles, the add/delete operations — counts columns this way instead,
/// which is also how `splitTableRow` counts them.
func columnSpans(in line: NSString) -> [(start: Int, end: Int)] {
    var edges = pipeEdges(in: line)
    guard !edges.isEmpty else { return [] }
    var result: [(start: Int, end: Int)] = []
    for ei in 0..<(edges.count - 1) {
        result.append((edges[ei] + 1, edges[ei + 1]))
    }
    return result
}

/// The pipe positions a row's cells sit between, with virtual edges standing in
/// for a missing outer pipe. Shared by `cellRanges` and `columnSpans`, which
/// differ only in what they do with an empty span.
private func pipeEdges(in line: NSString) -> [Int] {
    var pipePos: [Int] = []
    for ci in 0..<line.length {
        guard line.character(at: ci) == 0x7C else { continue }
        // A `\|` is escaped content, not a cell separator (GFM Example 200).
        if ci > 0 && line.character(at: ci - 1) == 0x5C { continue }
        pipePos.append(ci)
    }
    guard !pipePos.isEmpty else { return [] }
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
    return edges
}

/// Returns `(start, end)` character ranges for each cell in a table line.
/// Works with or without outer pipes. `start` is the first content char,
/// `end` is one past the last content char (i.e., the next pipe or line end).
func cellRanges(in line: NSString) -> [(start: Int, end: Int)] {
    columnSpans(in: line).filter { $0.end > $0.start }
}
