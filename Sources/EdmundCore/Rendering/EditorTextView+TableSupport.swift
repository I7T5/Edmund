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
    // separator stays valid GFM. In display columns, so a column of CJK lines
    // up in a monospace view (see `displayColumns`).
    var widths = [Int](repeating: 3, count: cols)
    for (i, line) in lines.enumerated() where i != 1 {
        let c = cells(line)
        for col in 0..<min(c.count, cols) {
            widths[col] = max(widths[col], displayColumns(c[col]))
        }
    }
    let markers: [String] = lines.count > 1 ? cells(lines[1]) : []

    func join(_ parts: [String]) -> String {
        let joined = parts.joined(separator: " | ")
        return outer ? "| \(joined) |" : joined
    }
    func bodyRow(_ texts: [String]) -> String {
        join((0..<cols).map { col in
            let t = col < texts.count ? texts[col] : ""
            return t + String(repeating: " ", count: max(0, widths[col] - displayColumns(t)))
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
    let edges = pipeEdges(in: line)
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

// MARK: - Moving rows and columns

/// A table's lines with a run of rows moved, for dragging a row by its pill.
///
/// Rows here are counted *without* the separator line: 0 is the header, 1 the
/// first body row. `gap` is the row the run lands in front of, counted the
/// same way before the move (the row count lands it after the last). The
/// separator stays on line 1 whatever moves, so a body row moved to the top
/// becomes the header and the old header drops into the body — the same
/// convention as adding a row above the header. Each row's text, padding
/// included, moves byte for byte. Nil when the move changes nothing.
func movedTableRows(_ lines: [String], from rows: ClosedRange<Int>, to gap: Int) -> [String]? {
    guard lines.count >= 2 else { return nil }
    var logical = [lines[0]] + lines.dropFirst(2)
    guard rows.lowerBound >= 0, rows.upperBound < logical.count,
          gap >= 0, gap <= logical.count,
          gap < rows.lowerBound || gap > rows.upperBound + 1 else { return nil }
    let run = Array(logical[rows])
    logical.removeSubrange(rows)
    logical.insert(contentsOf: run, at: gap > rows.upperBound ? gap - run.count : gap)
    return [logical[0], lines[1]] + logical.dropFirst()
}

/// A table's lines with a run of columns moved, for dragging a column by its
/// pill. Columns are counted as `columnSpans` counts them, off the header;
/// `gap` is the column the run lands in front of, before the move.
///
/// Every line moves the same cells, the separator's included, so a column's
/// alignment colons travel with it. A row short of the header's columns is
/// first given the empty cells it lacks — otherwise there would be nothing in
/// it to move. Cells move byte for byte, padding and all. Nil when the move
/// changes nothing.
func movedTableColumns(_ lines: [String], from columns: ClosedRange<Int>,
                       to gap: Int) -> [String]? {
    guard let header = lines.first else { return nil }
    let count = columnSpans(in: header as NSString).count
    guard columns.lowerBound >= 0, columns.upperBound < count,
          gap >= 0, gap <= count,
          gap < columns.lowerBound || gap > columns.upperBound + 1 else { return nil }
    return lines.enumerated().map { index, line in
        let ns = paddedTableRow(line, toColumns: count, separator: index == 1) as NSString
        let spans = columnSpans(in: ns)
        guard spans.count >= count else { return line }
        var cells = spans.map {
            ns.substring(with: NSRange(location: $0.start, length: $0.end - $0.start))
        }
        let run = Array(cells[columns])
        cells.removeSubrange(columns)
        cells.insert(contentsOf: run, at: gap > columns.upperBound ? gap - run.count : gap)
        // Spans sit between single pipes, so joining on one rebuilds the row;
        // whatever stands before the first and after the last (the outer
        // pipes, or nothing) is kept as it was.
        return ns.substring(to: spans[0].start) + cells.joined(separator: "|")
            + ns.substring(from: spans[spans.count - 1].end)
    }
}

/// A row given the empty cells it lacks to reach `count` columns, in its own
/// pipe style; the separator row's are dashes, or the table stops parsing.
/// A row that already has them comes back untouched.
func paddedTableRow(_ line: String, toColumns count: Int, separator: Bool) -> String {
    let have = columnSpans(in: line as NSString).count
    guard have > 0, have < count else { return line }
    var base = line
    while base.last == " " || base.last == "\t" { base.removeLast() }
    let cell = separator ? " --- " : "  "
    let closed = base.hasSuffix("|") && !base.hasSuffix("\\|")
    return base + String(repeating: closed ? cell + "|" : "|" + cell, count: count - have)
}

// MARK: - Pasting a grid of cells

/// Tab-separated text, as Numbers, Excel and Sheets put a block of cells on
/// the pasteboard, split into rows of fields.
///
/// A field that holds a tab, a newline or a quote comes quoted, with its
/// quotes doubled — the CSV convention (RFC 4180, §2), which spreadsheets
/// follow for tab-separated text too. A final line break ends the last row
/// rather than starting an empty one. Rows come back as long as the longest,
/// short ones filled with empty fields.
func parseTSV(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    var chars = text.makeIterator()
    var pending = chars.next()
    while let ch = pending {
        pending = chars.next()
        if quoted {
            if ch == "\"" {
                if pending == "\"" {
                    field.append("\"")
                    pending = chars.next()
                } else {
                    quoted = false
                }
            } else {
                field.append(ch)
            }
            continue
        }
        switch ch {
        case "\"" where field.isEmpty:
            quoted = true
        case "\t":
            row.append(field)
            field = ""
        // "\r\n" is one Character in Swift, so it needs its own case.
        case "\n", "\r", "\r\n":
            row.append(field)
            rows.append(row)
            row = []
            field = ""
        default:
            field.append(ch)
        }
    }
    if !field.isEmpty || !row.isEmpty {
        row.append(field)
        rows.append(row)
    }
    let width = rows.map(\.count).max() ?? 0
    return rows.map { $0 + Array(repeating: "", count: width - $0.count) }
}

/// Text from outside made safe for one markdown table cell: a cell cannot
/// hold a line break, and a bare `|` would end it.
func tableCellEscaped(_ text: String) -> String {
    var out = ""
    var previous: Character?
    for ch in text {
        switch ch {
        case "\n", "\r", "\r\n":
            out.append(" ")
        case "|" where previous != "\\":
            out.append("\\|")
        default:
            out.append(ch)
        }
        previous = ch
    }
    return out.trimmingCharacters(in: .whitespaces)
}

/// A table's lines with `grid` written over its cells from line `row`,
/// column `column` on, as a spreadsheet pastes: each value replaces a cell
/// whole, and the table grows the rows and columns the grid runs past.
///
/// Rows run down the table skipping the separator, so a grid pasted at the
/// header carries on into the first body row. Columns are counted as
/// `columnSpans` counts them. Cells the grid does not reach keep their bytes.
func pastedTableLines(_ lines: [String], grid: [[String]], row: Int, column: Int) -> [String] {
    guard let header = lines.first, lines.count >= 2, row != 1, row >= 0,
          row < lines.count, column >= 0 else { return lines }
    let gridWidth = grid.map(\.count).max() ?? 0
    let width = max(columnSpans(in: header as NSString).count, column + gridWidth)
    var edited = lines.enumerated().map { index, line in
        paddedTableRow(line, toColumns: width, separator: index == 1)
    }
    let outer = header.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    let emptyRow = outer
        ? "|" + String(repeating: "  |", count: width)
        : Array(repeating: "  ", count: width).joined(separator: "|")
    let firstLogical = row == 0 ? 0 : row - 1
    for (offset, values) in grid.enumerated() {
        let logical = firstLogical + offset
        let line = logical == 0 ? 0 : logical + 1
        while edited.count <= line { edited.append(emptyRow) }
        edited[line] = writingCells(edited[line], values, from: column)
    }
    return edited
}

/// A table's lines with every cell of a block set to one value — a single
/// copied cell pasted over a selected block, which a spreadsheet fills.
func filledTableLines(_ lines: [String], block: TableCellBlock, with value: String) -> [String] {
    lines.enumerated().map { index, line in
        guard index != 1, block.rows.contains(index) else { return line }
        return writingCells(line, Array(repeating: value, count: block.columns.count),
                            from: block.columns.lowerBound)
    }
}

/// One row with `values` written into its cells from `column` on, each cell
/// padded by a space either side (an empty one as two spaces, the way the
/// editor writes an empty cell). Right to left, so earlier offsets hold.
private func writingCells(_ line: String, _ values: [String], from column: Int) -> String {
    let row = NSMutableString(string: line)
    let spans = columnSpans(in: row)
    for (i, value) in values.enumerated().reversed() {
        let index = column + i
        guard index < spans.count else { continue }
        let span = spans[index]
        row.replaceCharacters(in: NSRange(location: span.start, length: span.end - span.start),
                              with: value.isEmpty ? "  " : " \(value) ")
    }
    return row as String
}

// MARK: - Formatting a table's source

/// A table's lines in the canonical aligned form, for formatting a table once
/// the caret leaves it, or nil when there is nothing to do: the table is
/// already aligned, or aligning it would lose text.
///
/// `prettyAlignedTableLines` keeps the header's column count and drops any
/// cell past it. GFM ignores such a cell too (spec example 204), but it is
/// still text the author typed, and a format must never delete it — so a
/// table with one is left as it is. Empty cells past the header go quietly.
func formattedTableLines(_ lines: [String]) -> [String]? {
    guard let header = lines.first, lines.count >= 2 else { return nil }
    let columns = columnSpans(in: header as NSString).count
    guard columns > 0 else { return nil }
    for (index, line) in lines.enumerated() where index != 1 {
        let ns = line as NSString
        let spans = columnSpans(in: ns)
        guard spans.count > columns else { continue }
        for span in spans[columns...] {
            let text = ns.substring(with: NSRange(location: span.start,
                                                  length: span.end - span.start))
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        }
    }
    let formatted = prettyAlignedTableLines(lines)
    return formatted == lines ? nil : formatted
}

/// How many columns `text` takes in a monospace font: two for an East Asian
/// Wide or Fullwidth character and for an emoji drawn as one, one for
/// anything else. A close reading of Unicode's East Asian Width property
/// (UAX #11, https://www.unicode.org/reports/tr11/) by code-point block, the
/// same approach as Markus Kuhn's `wcwidth`; exact for CJK, Hangul and kana,
/// which is what a table's alignment needs.
func displayColumns(_ text: String) -> Int {
    text.reduce(0) { $0 + (characterIsWide($1) ? 2 : 1) }
}

private func characterIsWide(_ character: Character) -> Bool {
    guard let first = character.unicodeScalars.first else { return false }
    if first.properties.isEmojiPresentation { return true }
    // A text-style emoji asked to draw as an emoji (U+FE0F) is wide too.
    if first.properties.isEmoji, character.unicodeScalars.contains(where: { $0.value == 0xFE0F }) {
        return true
    }
    switch first.value {
    case 0x1100...0x115F,   // Hangul Jamo initials
         0x2E80...0x303E,   // CJK radicals, punctuation
         0x3041...0x33FF,   // kana, CJK symbols
         0x3400...0x4DBF,   // CJK Extension A
         0x4E00...0x9FFF,   // CJK Unified Ideographs
         0xA000...0xA4CF,   // Yi
         0xAC00...0xD7A3,   // Hangul syllables
         0xF900...0xFAFF,   // CJK Compatibility Ideographs
         0xFE30...0xFE4F,   // CJK Compatibility Forms
         0xFF00...0xFF60,   // Fullwidth forms
         0xFFE0...0xFFE6,
         0x20000...0x2FFFD, // CJK Extensions B–F
         0x30000...0x3FFFD:
        return true
    default:
        return false
    }
}
