import AppKit

// MARK: - Editing a table in place
//
// A table stays rendered with the caret inside it (see the `.table` case in
// `styleBlock`), so the cell under the caret is edited directly in the
// document's own storage — there is no separate field, and no write-back.
// Ordinary typing therefore needs nothing at all here.
//
// Two keys do need intercepting, because in a table their plain meaning
// destroys the structure rather than editing it:
//
//   * Return would split the row's line in two, which cuts the cell's text in
//     half and leaves both fragments as rows (`| c1` / `1 | c12 |`). It adds a
//     row instead.
//   * Tab would indent, which is meaningless mid-row. It steps to the next
//     cell, which is what every other table editor does and the only quick way
//     to reach a cell whose text is too short to click accurately.
//
// Both are suppressed while the table is showing its raw markdown (the `</>`
// button): there the pipes are visible and the user is editing the source by
// hand, so Return and Tab should do their ordinary thing.

extension EditorTextView {

    /// The cell the caret is in, if it is in a table being edited in place.
    /// Nil while the table is deliberately raw.
    ///
    /// A non-empty selection still counts: Tab leaves the cell it steps to
    /// selected, so requiring an empty one would make only the first Tab work.
    var inlineTableCell: TableCellRef? {
        guard !rawTableEditing else { return nil }
        return tableCell(atRawOffset: selectedRange().location)
    }

    // MARK: - Return: add a row

    /// Adds an empty row below the caret's row and puts the caret in its first
    /// cell. Returns false if the caret isn't in an in-place table.
    func handleTableNewline() -> Bool {
        guard let cell = inlineTableCell else { return false }
        let ns = rawSource as NSString
        let line = ns.lineRange(for: NSRange(location: cell.contentRange.location, length: 0))
        let lineText = ns.substring(with: line)
        // Count the columns off the line without its newline: a trailing `\n`
        // after the closing pipe reads as one more (empty) cell, and the new
        // row would come out a column too wide.
        let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
        let columns = cellRanges(in: trimmed as NSString).count
        guard columns > 0 else { return false }

        // Match the row above: a table written without outer pipes must not
        // gain them, or the new row parses with an extra empty column.
        let outer = trimmed.hasPrefix("|")
        let body = Array(repeating: "  ", count: columns).joined(separator: "|")
        let row = (outer ? "|\(body)|" : body)

        // `line` includes its trailing newline except on the document's last
        // line, where the newline has to be added rather than reused.
        let endsWithNewline = line.upperBound <= ns.length
            && lineText.hasSuffix("\n")
        let insertAt = endsWithNewline ? line.upperBound : ns.length
        let replacement = endsWithNewline ? row + "\n" : "\n" + row

        // The caret lands in the new row's first cell — one character past the
        // leading pipe and its space, which is where its content begins.
        let caret = insertAt + (endsWithNewline ? 0 : 1) + (outer ? 2 : 1)
        applyFormattingEdit(rawRange: NSRange(location: insertAt, length: 0),
                            replacement: replacement,
                            select: NSRange(location: caret, length: 0))
        return true
    }

    // MARK: - Tab: step between cells

    /// Moves the caret to the next (`+1`) or previous (`-1`) cell, selecting
    /// its text so typing replaces it — the same bargain a spreadsheet makes.
    /// Stepping past the last cell of a row wraps to the next row; past the
    /// last cell of the table it does nothing, rather than adding a row, since
    /// Return is the way to do that deliberately.
    @discardableResult
    func stepTableCell(by delta: Int) -> Bool {
        guard let cell = inlineTableCell else { return false }
        var row = cell.row
        var column = cell.column + delta
        // Row 1 is the separator: it holds no editable cell, so a step off
        // either end of the header or the first body row skips over it.
        if column < 0 {
            row -= (row == 2 ? 2 : 1)
            guard row >= 0, let previous = lastColumn(blockIndex: cell.blockIndex, row: row)
            else { return false }
            column = previous
        } else if tableCell(blockIndex: cell.blockIndex, row: row, column: column) == nil {
            row += (row == 0 ? 2 : 1)
            column = 0
        }
        guard let target = tableCell(blockIndex: cell.blockIndex,
                                     row: row, column: column) else { return false }

        // Select the cell's text, not its surrounding padding spaces, so
        // typing replaces the value the way a spreadsheet does.
        let ns = rawSource as NSString
        var lo = target.contentRange.location
        var hi = min(target.contentRange.upperBound, ns.length)
        while lo < hi, ns.character(at: lo) == 0x20 { lo += 1 }
        while hi > lo, ns.character(at: hi - 1) == 0x20 { hi -= 1 }
        setSelectedRange(NSRange(location: lo, length: hi - lo))
        scrollRangeToVisible(selectedRange())
        return true
    }

    /// The index of the last cell in a row, or nil if the row has none.
    private func lastColumn(blockIndex: Int, row: Int) -> Int? {
        var last: Int?
        var column = 0
        while tableCell(blockIndex: blockIndex, row: row, column: column) != nil {
            last = column
            column += 1
        }
        return last
    }
}
