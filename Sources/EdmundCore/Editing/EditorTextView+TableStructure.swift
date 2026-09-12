import AppKit

// MARK: - Changing a table's shape
//
// Adding and removing rows and columns, for the row and column handles and the
// cell context menu. Rows are a line insert or delete; columns touch every line
// at once, so they go through `applyFormattingEdit` on the whole table block —
// still one undo step, since the block is contiguous.
//
// Every operation *splices*: it writes the few characters the change needs at
// the offsets that need them and leaves the rest of the table byte-identical.
// Rebuilding each row from its cells would be shorter but would silently
// reformat a hand-written table's padding on any structural edit.
//
// Columns are counted the way `columnSpans` counts them, which keeps an empty
// `||` cell — see the note there.
//
// The header row is not special-cased away. GFM needs a header, so "add a row
// above the header" makes the new row the header and demotes the old one, and
// "delete the header" promotes the row after it. Both are literally a line
// insert or delete at index 0 — the separator stays where it is and the next
// row becomes the header for free.

extension EditorTextView {

    // MARK: - What is allowed

    /// The table's lines, or nil if `blockIndex` isn't a table.
    func tableLines(blockIndex: Int) -> [String]? {
        guard blockIndex >= 0, blockIndex < blocks.count,
              blocks[blockIndex].kind == .table else { return nil }
        return blocks[blockIndex].content.components(separatedBy: "\n")
    }

    /// How many columns the table has, counted off its header row.
    func tableColumnCount(blockIndex: Int) -> Int {
        guard let lines = tableLines(blockIndex: blockIndex), let header = lines.first
        else { return 0 }
        return columnSpans(in: header as NSString).count
    }

    /// Deleting the header is only offered when there is a body row to promote
    /// into it; deleting any other row only needs that row to exist. Row 1 is
    /// the separator and is never a target.
    func canDeleteTableRow(blockIndex: Int, row: Int) -> Bool {
        guard let lines = tableLines(blockIndex: blockIndex),
              row != 1, lines.indices.contains(row) else { return false }
        return row > 0 || lines.count > 2
    }

    func canDeleteTableColumn(blockIndex: Int, column: Int) -> Bool {
        tableColumnCount(blockIndex: blockIndex) > 1
            && column >= 0 && column < tableColumnCount(blockIndex: blockIndex)
    }

    // MARK: - Rows

    /// Inserts an empty row at line `row`, and puts the caret in its `column`.
    func insertTableRow(blockIndex: Int, at row: Int, column: Int = 0) {
        guard let lines = tableLines(blockIndex: blockIndex),
              row != 1, row >= 0, row <= lines.count,
              let header = lines.first else { return }
        let columns = columnSpans(in: header as NSString).count
        guard columns > 0 else { return }

        // Match the header's pipe style: a table written without outer pipes
        // must not gain them, or the new row parses a column wider.
        let outer = header.trimmingCharacters(in: .whitespaces).hasPrefix("|")
        let body = Array(repeating: "  ", count: columns).joined(separator: "|")
        let newRow = outer ? "|\(body)|" : body

        if row == 0 {
            // The separator has to stay on line 1, so a row above the header
            // cannot simply land first: the new row takes the header's place
            // and the old header drops to the top of the body, under the
            // separator. Two line moves, so the whole table is rewritten.
            guard lines.count >= 2 else { return }
            var edited = lines
            edited.insert(newRow, at: 0)
            edited.swapAt(1, 2)
            replaceTable(blockIndex: blockIndex, lines: edited)
            landInCell(blockIndex: blockIndex, row: 0, column: column)
            return
        }

        let block = blocks[blockIndex]
        // Appending past the last line has to reuse the newline before it
        // rather than the one after, which may not exist.
        let atEnd = row == lines.count
        let offset = block.range.location
            + (atEnd ? (block.content as NSString).length : lineStart(in: lines, row: row))
        applyFormattingEdit(rawRange: NSRange(location: offset, length: 0),
                            replacement: atEnd ? "\n" + newRow : newRow + "\n",
                            select: NSRange(location: offset, length: 0))
        landInCell(blockIndex: blockIndex, row: row, column: column)
    }

    /// Deletes line `row`, and puts the caret in the row that takes its place.
    func deleteTableRow(blockIndex: Int, row: Int, column: Int = 0) {
        guard canDeleteTableRow(blockIndex: blockIndex, row: row),
              let lines = tableLines(blockIndex: blockIndex) else { return }

        if row == 0 {
            // Mirror of the insert above: the first body row is promoted into
            // the header's place and leaves its own, so the separator stays on
            // line 1. Deleting line 0 alone would make the separator the header.
            var edited = lines
            edited[0] = lines[2]
            edited.remove(at: 2)
            replaceTable(blockIndex: blockIndex, lines: edited)
            landInCell(blockIndex: blockIndex, row: 0, column: column)
            return
        }

        let block = blocks[blockIndex]
        let start = lineStart(in: lines, row: row)
        let length = (lines[row] as NSString).length
        // Every line but the last is followed by its newline; the last one is
        // preceded by the newline that has to go with it.
        let last = row == lines.count - 1
        let cut = last
            ? NSRange(location: start - 1, length: length + 1)
            : NSRange(location: start, length: length + 1)
        applyFormattingEdit(rawRange: NSRange(location: block.range.location + cut.location,
                                              length: cut.length),
                            replacement: "",
                            select: NSRange(location: block.range.location, length: 0))
        // The row below has slid up into this index; at the end, step back.
        landInCell(blockIndex: blockIndex, row: last ? row - 1 : row, column: column)
    }

    // MARK: - Columns

    /// Inserts an empty column at index `column` in every row, and puts the
    /// caret in the new cell of `row`.
    func insertTableColumn(blockIndex: Int, at column: Int, row: Int = 0) {
        guard let lines = tableLines(blockIndex: blockIndex), column >= 0,
              column <= tableColumnCount(blockIndex: blockIndex) else { return }
        let edited = lines.enumerated().map { index, line -> String in
            let ns = line as NSString
            let spans = columnSpans(in: ns)
            guard !spans.isEmpty else { return line }
            // The separator row's new cell has to be dashes, or the table stops
            // parsing as one.
            let cell = index == 1 ? " --- " : "  "
            // A ragged row short of this column gains its cell at the end.
            guard column < spans.count else {
                return ns.replacingCharacters(
                    in: NSRange(location: spans[spans.count - 1].end, length: 0),
                    with: "|" + cell)
            }
            return ns.replacingCharacters(
                in: NSRange(location: spans[column].start, length: 0), with: cell + "|")
        }
        replaceTable(blockIndex: blockIndex, lines: edited)
        landInCell(blockIndex: blockIndex, row: row, column: column)
    }

    /// Removes column `column` from every row, and puts the caret in the cell
    /// that takes its place in `row`.
    func deleteTableColumn(blockIndex: Int, column: Int, row: Int = 0) {
        guard canDeleteTableColumn(blockIndex: blockIndex, column: column),
              let lines = tableLines(blockIndex: blockIndex) else { return }
        let edited = lines.map { line -> String in
            let ns = line as NSString
            let spans = columnSpans(in: ns)
            guard column < spans.count else { return line }   // ragged: nothing to cut
            let span = spans[column]
            // A cell goes with one of the pipes beside it: the one before,
            // unless it is the first cell, which takes the one after.
            let cut: NSRange
            if column > 0 {
                cut = NSRange(location: span.start - 1, length: span.end - span.start + 1)
            } else {
                let trailing = span.end < ns.length && ns.character(at: span.end) == 0x7C
                cut = NSRange(location: span.start,
                              length: span.end - span.start + (trailing ? 1 : 0))
            }
            return ns.replacingCharacters(in: cut, with: "")
        }
        replaceTable(blockIndex: blockIndex, lines: edited)
        landInCell(blockIndex: blockIndex, row: row, column: max(0, column - 1))
    }

    // MARK: - Delete on a cell selection

    /// Delete pressed while a block of cells is selected, after Apple Notes:
    /// a *complete* row or column selection whose cells are already empty is
    /// removed; every other case clears the cells' contents and leaves the grid
    /// intact. So the first Delete empties a full row/column and a second one
    /// removes it — and the "already empty" gate is what lets a two-column table
    /// tell "clear this row" from "delete it", since there any horizontal
    /// selection covers every column. The whole table (every row *and* column)
    /// only ever clears; removing the block is a separate operation. Returns
    /// false when no block of cells is selected, so an ordinary delete runs.
    func handleTableCellSelectionDelete() -> Bool {
        guard let block = tableCellSelection,
              let lines = tableLines(blockIndex: block.blockIndex) else { return false }
        let lastRow = lines.count - 1
        let cols = tableColumnCount(blockIndex: block.blockIndex)
        let allRows = block.rows.lowerBound == 0 && block.rows.upperBound >= lastRow
        let allCols = block.columns.lowerBound == 0 && block.columns.upperBound >= cols - 1

        if tableCellsAreEmpty(block) {
            if allCols && !allRows {            // complete, empty row(s) → delete them
                for row in block.rows.reversed() where row != 1 {
                    deleteTableRow(blockIndex: block.blockIndex, row: row,
                                   column: block.columns.lowerBound)
                }
                return true
            }
            if allRows && !allCols {            // complete, empty column(s) → delete them
                for column in block.columns.reversed() {
                    deleteTableColumn(blockIndex: block.blockIndex, column: column,
                                      row: block.rows.lowerBound)
                }
                return true
            }
        }
        clearTableCells(block)
        return true
    }

    /// Whether every selected cell (the separator row aside) is already empty —
    /// the condition Notes uses to turn a second Delete into a row/column
    /// removal rather than another clear.
    func tableCellsAreEmpty(_ block: TableCellBlock) -> Bool {
        guard let lines = tableLines(blockIndex: block.blockIndex) else { return false }
        for row in block.rows where row != 1 && lines.indices.contains(row) {
            let ns = lines[row] as NSString
            let spans = columnSpans(in: ns)
            for column in block.columns where column < spans.count {
                let span = spans[column]
                let text = ns.substring(with: NSRange(location: span.start,
                                                      length: span.end - span.start))
                    .trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { return false }
            }
        }
        return true
    }

    /// Blanks every selected cell's content to a single padded empty cell, as
    /// one undoable edit. The pipes and the padding stay; only the text goes.
    func clearTableCells(_ block: TableCellBlock) {
        guard var lines = tableLines(blockIndex: block.blockIndex) else { return }
        for row in block.rows where row != 1 && lines.indices.contains(row) {
            let mut = NSMutableString(string: lines[row])
            let spans = columnSpans(in: mut)
            // Right to left, so an earlier span's offsets survive a later edit.
            for column in block.columns.reversed() where column < spans.count {
                let span = spans[column]
                mut.replaceCharacters(in: NSRange(location: span.start,
                                                  length: span.end - span.start),
                                      with: "  ")
            }
            lines[row] = mut as String
        }
        replaceTable(blockIndex: block.blockIndex, lines: lines)
        // Keep the cells selected, not a caret: clearing doesn't change the
        // grid, and holding the selection is what lets a second Delete on a now-
        // empty complete row/column remove it (the Notes two-press behaviour).
        selectTableCells(blockIndex: block.blockIndex,
                         from: (block.rows.lowerBound, block.columns.lowerBound),
                         to: (block.rows.upperBound, block.columns.upperBound))
    }

    // MARK: - Finishing a header + separator

    /// Return pressed on a table that is still just a header and its separator:
    /// pad the separator's dash runs to the header columns' widths and drop in
    /// one empty body row to type into, landing the caret in its first cell.
    ///
    /// This is the "autocomplete a table once the header and the `-|-` are
    /// there" affordance. Return from the header row is already handled
    /// (`handleTableNewline` adds a body row); the gap is Return from the
    /// *separator* line, where the caret is in no cell, so this fills it.
    /// Returns false when the caret isn't on the separator of a body-less table.
    func handleTableSeparatorNewline() -> Bool {
        guard !rawTableEditing, selectedRange().length == 0,
              let blockIndex = blockIndexForRawOffset(selectedRange().location),
              let lines = tableLines(blockIndex: blockIndex),
              lines.count == 2 else { return false }   // header + separator only
        // The caret must be on the separator line (line 1), not the header.
        let block = blocks[blockIndex]
        let separatorStart = block.range.location + (lines[0] as NSString).length + 1
        guard selectedRange().location >= separatorStart else { return false }

        let padded = paddedSeparatorLine(header: lines[0], separator: lines[1])
        // Match the header's pipe style, exactly as insertTableRow does, so a
        // table written without outer pipes doesn't gain them here.
        let outer = lines[0].trimmingCharacters(in: .whitespaces).hasPrefix("|")
        let columns = columnSpans(in: lines[0] as NSString).count
        guard columns > 0 else { return false }
        let cells = Array(repeating: "  ", count: columns).joined(separator: "|")
        let body = outer ? "|\(cells)|" : cells

        replaceTable(blockIndex: blockIndex, lines: [lines[0], padded, body])
        landInCell(blockIndex: blockIndex, row: 2, column: 0)
        return true
    }

    /// A separator line whose dash run in each column is as wide as that
    /// column's header text, `:` alignment markers kept and the run floored at
    /// three dashes so a short header stays valid GFM. The column count follows
    /// the header, which also tidies a ragged separator.
    private func paddedSeparatorLine(header: String, separator: String) -> String {
        let h = header as NSString
        let widths = columnSpans(in: h).map { span -> Int in
            h.substring(with: NSRange(location: span.start, length: span.end - span.start))
                .trimmingCharacters(in: .whitespaces).count
        }
        let s = separator as NSString
        let existing = columnSpans(in: s).map { span -> String in
            s.substring(with: NSRange(location: span.start, length: span.end - span.start))
                .trimmingCharacters(in: .whitespaces)
        }
        let cells = widths.indices.map { i -> String in
            let marker = i < existing.count ? existing[i] : ""
            let lead = marker.hasPrefix(":")
            let trail = marker.count > 1 && marker.hasSuffix(":")
            let dashes = max(1, max(3, widths[i]) - (lead ? 1 : 0) - (trail ? 1 : 0))
            return (lead ? ":" : "") + String(repeating: "-", count: dashes) + (trail ? ":" : "")
        }
        let joined = cells.joined(separator: " | ")
        return header.trimmingCharacters(in: .whitespaces).hasPrefix("|") ? "| \(joined) |" : joined
    }

    // MARK: - Shared

    /// Character offset of line `row` within the table's own content.
    private func lineStart(in lines: [String], row: Int) -> Int {
        lines.prefix(row).reduce(0) { $0 + ($1 as NSString).length + 1 }
    }

    /// Writes a whole table back as one undoable edit. Columns need this: their
    /// change lands on every line, and a table block is contiguous, so the whole
    /// block is the smallest range that covers it.
    private func replaceTable(blockIndex: Int, lines: [String]) {
        let block = blocks[blockIndex]
        applyFormattingEdit(rawRange: block.range,
                            replacement: lines.joined(separator: "\n"),
                            select: NSRange(location: block.range.location, length: 0))
    }

    /// Selects a cell by position *after* an edit, when the ranges captured
    /// before it are all stale. Silently does nothing if the cell no longer
    /// exists — a delete can leave fewer rows or columns than the caller hoped.
    private func landInCell(blockIndex: Int, row: Int, column: Int) {
        guard let cell = tableCell(blockIndex: blockIndex, row: row, column: column)
                ?? tableCell(blockIndex: blockIndex, row: row, column: 0) else { return }
        selectCellText(cell)
    }
}
