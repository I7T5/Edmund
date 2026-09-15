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
//     half and leaves both fragments as rows (`| c1` / `1 | c12 |`). It moves
//     down a row instead, and makes one when there is none below.
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

    // MARK: - Return: down a row, or a new one

    /// Return inside a table: from the header it inserts a new body row below
    /// and lands there; from any other row it moves to the cell below, adding a
    /// row when there is none. Returns false if the caret isn't in an in-place
    /// table.
    func handleTableNewline() -> Bool {
        guard let cell = inlineTableCell else { return false }
        // Return from the header inserts a fresh body row directly below and
        // lands in it: a header is where you set the columns up, so the next
        // keystroke is almost always the first data row, not a step into
        // whatever row happens to already be there. Row 1 is the separator, so
        // "directly below the header" is line 2.
        if cell.row == 0 {
            insertTableRow(blockIndex: cell.blockIndex, at: 2, column: cell.column)
            return true
        }
        // Every other row moves to the cell below and selects its text, the way
        // Return does in a spreadsheet. Falling back to column 0 covers a
        // ragged row that is short of the column the caret was in.
        let below = cell.row + 1
        if let target = tableCell(blockIndex: cell.blockIndex, row: below, column: cell.column)
            ?? tableCell(blockIndex: cell.blockIndex, row: below, column: 0) {
            selectCellText(target)
            return true
        }
        // No row below: make one, in the column the user was already in, so
        // Return down a column carries on down it.
        insertTableRow(blockIndex: cell.blockIndex, at: cell.row + 1, column: cell.column)
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

        selectCellText(target)
        return true
    }

    /// Selects a cell's text without its padding spaces, so typing replaces the
    /// value the way a spreadsheet does. Tab, Return and the structural
    /// operations all land this way.
    func selectCellText(_ cell: TableCellRef) {
        let ns = rawSource as NSString
        var lo = cell.contentRange.location
        var hi = min(cell.contentRange.upperBound, ns.length)
        while lo < hi, ns.character(at: lo) == 0x20 { lo += 1 }
        while hi > lo, ns.character(at: hi - 1) == 0x20 { hi -= 1 }
        if lo == hi {
            // An empty cell has no text to select, and trimming has run the
            // caret to the far end of its padding — where typing would eat the
            // space before the closing pipe. One space in keeps `|  |` padded
            // on both sides as it fills.
            lo = min(cell.contentRange.location + 1, hi)
            hi = lo
        }
        setSelectedRange(NSRange(location: lo, length: hi - lo))
        scrollRangeToVisible(selectedRange())
    }

    // MARK: - The padding a row keeps around its pipes

    /// Whether the character at `offset` is one of the spaces a table row keeps
    /// either side of a pipe.
    ///
    /// They are markdown's convention, not content: `|c21|` and `| c21 |` render
    /// identically, and every table this editor writes uses the spaced form. A
    /// caret cannot rest out there (see `tableCellCaretResting`), so the only way
    /// to reach one is a delete aimed past the end of a cell's text — which is
    /// a keystroke meant for the text, not for the delimiter beyond it.
    ///
    /// Content is never protected: only a space, and only one standing directly
    /// against a pipe. The separator row has no cells to look up, so its dashes
    /// are left alone entirely.
    func tableCellPadding(at offset: Int) -> Bool {
        guard !rawTableEditing, offset >= 0 else { return false }
        let ns = rawSource as NSString
        guard offset < ns.length, ns.character(at: offset) == 0x20,
              tableCell(atRawOffset: offset) != nil else { return false }
        let before = offset > 0 ? ns.character(at: offset - 1) : 0
        let after = offset + 1 < ns.length ? ns.character(at: offset + 1) : 0
        return before == 0x7C || after == 0x7C
    }

    /// Whether the character at `offset` is a table's structural pipe — a `|`
    /// that separates or bounds cells, not an escaped `\|` in content.
    func tableStructuralPipe(at offset: Int) -> Bool {
        guard !rawTableEditing, offset >= 0 else { return false }
        let ns = rawSource as NSString
        guard offset < ns.length, ns.character(at: offset) == 0x7C,
              !(offset > 0 && ns.character(at: offset - 1) == 0x5C),
              blockIndexForRawOffset(offset).map({ blocks[$0].kind == .table }) ?? false
        else { return false }
        return true
    }

    /// Whether removing `range` would take a pipe or the padding beside one with
    /// it. Every delete command (backspace, forward, ⌥⌫ word, ⌘⌫ line, cut) and
    /// any type-over of a selection reaches the storage through
    /// `shouldChangeText`, which consults this — so the structure is protected
    /// once, whatever key produced the edit, rather than one override per
    /// selector. Content is never protected: only the pipes and the single
    /// space standing against each.
    func deletionHitsTableStructure(_ range: NSRange) -> Bool {
        guard !rawTableEditing, range.length > 0 else { return false }
        let ns = rawSource as NSString
        let upper = min(range.upperBound, ns.length)
        var i = max(0, range.location)
        while i < upper {
            if tableStructuralPipe(at: i) || tableCellPadding(at: i)
                || tableRowJoiningNewline(at: i) { return true }
            i += 1
        }
        return false
    }

    /// Whether the character at `offset` is the newline joining two rows of one
    /// table. In every column but the first, a backspace is stopped by the pipe
    /// or pad it would hit; at the first column's line start there is neither —
    /// the character behind the caret is this newline, and deleting it merges the
    /// row into the one above (the same merge a forward-delete at a row's end
    /// would make from below). Both ends being in the same table block is the
    /// test: a table block's range spans its internal newlines, so only a
    /// row-joining newline has table on both sides.
    func tableRowJoiningNewline(at offset: Int) -> Bool {
        guard !rawTableEditing, offset > 0 else { return false }
        let ns = rawSource as NSString
        guard offset + 1 < ns.length, ns.character(at: offset) == 0x0A else { return false }
        guard let before = blockIndexForRawOffset(offset - 1),
              let after = blockIndexForRawOffset(offset + 1),
              before == after, blocks[before].kind == .table else { return false }
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
