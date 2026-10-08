import AppKit

// MARK: - Copying out of a table
//
// A table's storage is its markdown, pipes and padding included, so a plain ⌘C
// hands the next app a row of `| c21 | c22 |`. Two cases are worth more than
// that:
//
//   * the caret sitting in a cell copies that cell's content — what the user is
//     looking at, without the delimiters or the column's padding;
//   * a block of selected cells copies as tab-separated rows, which Numbers,
//     Excel and Sheets all split into real cells on paste.
//
// Everything else — a selection inside one cell, anything outside a table —
// goes to `super` untouched.
//
// A block of cells also goes on the pasteboard as Edmund's own cell grid, each
// cell's markdown as written, so that inside Edmund it pastes back as cells:
// into a table it fills the cells from the caret's, the way a spreadsheet
// does; anywhere else it becomes a new table. A grid copied from Numbers,
// Excel or Sheets fills cells the same way. ⌘X takes the cells' contents and
// leaves the grid, as a spreadsheet does.

/// A block of cells as Edmund puts it on the pasteboard.
struct TableCellsClip: Codable, Equatable {
    /// Row by row, each cell's markdown as written, without its padding.
    let cells: [[String]]
    /// The copied columns' separator markers (`---`, `:-:`, …), so a table
    /// made from the clip aligns its columns as the source did.
    let aligns: [String]

    /// Computed rather than stored: a stored static of an AppKit type is a
    /// shared global that Swift 6's concurrency checking will not vouch for.
    static var pasteboardType: NSPasteboard.PasteboardType { .init("com.i7t5.edmund.table-cells") }
}

extension EditorTextView {

    /// Paste, then tidy the delimiters of any table the paste landed in.
    ///
    /// Markdown tolerates a table written without its outer pipes and without
    /// the spaces either side of the inner ones, and plenty of sources emit
    /// exactly that — so a pasted table renders, but the source underneath it
    /// reads nothing like the ones this editor writes. Only the delimiters are
    /// touched; the pasted text itself is never reflowed.
    public override func paste(_ sender: Any?) {
        // Image content (files, bitmaps, web URLs) attaches as markdown first;
        // see EditorTextView+ImageAttachments.
        if handleImagePasteboard(NSPasteboard.general, at: nil, linkOnly: false) { return }
        // A list pasted into a list is rewritten first; see EditorTextView+ListPaste.
        if let adjusted = listAdjustedPasteText() {
            insertText(adjusted, replacementRange: selectedRange())
            return
        }
        // Cells, from this editor or a spreadsheet; see `pasteTableCells`.
        if pasteTableCells(from: NSPasteboard.general) { return }
        let before = selectedRange()
        super.paste(sender)
        let after = selectedRange()
        let start = min(before.location, after.location)
        normalizeTableDelimiters(in: NSRange(location: start,
                                             length: max(0, after.upperBound - start)))
    }

    /// Rewrites every table the span touches to the conventional skeleton.
    ///
    /// Back to front, so rewriting one table cannot shift the range of another
    /// still to be done. A table already conventional is skipped outright,
    /// which is what keeps this from filing an undo step for a no-op.
    func normalizeTableDelimiters(in span: NSRange) {
        guard span.length > 0, !rawTableEditing else { return }
        let ns = rawSource as NSString
        let targets = blocks.filter {
            $0.kind == .table && NSIntersectionRange($0.range, span).length > 0
        }
        for block in targets.reversed() {
            let location = min(block.range.location, ns.length)
            let range = NSRange(location: location,
                                length: min(block.range.length, ns.length - location))
            guard range.length > 0,
                  let normalized = normalizedTableBlock(ns.substring(with: range))
            else { continue }
            let caret = range.location + (normalized as NSString).length
            applyFormattingEdit(rawRange: range, replacement: normalized,
                                select: NSRange(location: caret, length: 0))
        }
    }

    /// What ⌘C should put on the pasteboard for a selection in a table, or nil
    /// when the ordinary copy is the right one.
    func tableCopyText() -> String? {
        guard !rawTableEditing else { return nil }
        if let block = tableCellSelection { return tableSpreadsheetText(block) }
        guard selectedRange().length == 0, let cell = activeTableCell else { return nil }
        return tableCellText(cell)
    }

    /// The block of cells ⌘C and ⌘X act on, if one is selected: a picked row
    /// or column, or a block dragged out across cells.
    var tableClipBlock: TableCellBlock? {
        guard !rawTableEditing else { return nil }
        return tableAxisSelection?.block ?? tableCellSelection
    }

    /// Puts a block of cells on the pasteboard: tab-separated for other apps,
    /// and as Edmund's own grid for pasting back here.
    func writeTableCells(_ block: TableCellBlock, to pasteboard: NSPasteboard) {
        let clip = tableCellsClip(block)
        pasteboard.declareTypes([.string, TableCellsClip.pasteboardType], owner: nil)
        pasteboard.setString(tableSpreadsheetText(block), forType: .string)
        if let data = try? JSONEncoder().encode(clip) {
            pasteboard.setData(data, forType: TableCellsClip.pasteboardType)
        }
    }

    /// ⌘X on a block of cells: copy them, then empty them. The rows and
    /// columns stay, as in a spreadsheet; Delete is what removes them.
    public override func cut(_ sender: Any?) {
        if cutTableCells(to: .general) { return }
        super.cut(sender)
    }

    /// The cut itself, onto any pasteboard. False when no block of cells is
    /// selected.
    func cutTableCells(to pasteboard: NSPasteboard) -> Bool {
        guard let block = tableClipBlock else { return false }
        writeTableCells(block, to: pasteboard)
        clearTableCells(block)
        return true
    }

    /// The block's cells as markdown, and its columns' separator markers.
    func tableCellsClip(_ block: TableCellBlock) -> TableCellsClip {
        let cells = block.rows.compactMap { row -> [String]? in
            guard row != 1 else { return nil }
            let texts = block.columns.compactMap { column in
                tableCell(blockIndex: block.blockIndex, row: row, column: column)
                    .map { tableCellText($0) }
            }
            return texts.isEmpty ? nil : texts
        }
        var aligns: [String] = []
        if let lines = tableLines(blockIndex: block.blockIndex), lines.count > 1 {
            let separator = lines[1] as NSString
            let markers = cellRanges(in: separator).map {
                separator.substring(with: NSRange(location: $0.start, length: $0.end - $0.start))
                    .trimmingCharacters(in: .whitespaces)
            }
            aligns = block.columns.map { $0 < markers.count ? markers[$0] : "---" }
        }
        return TableCellsClip(cells: cells, aligns: aligns)
    }

    // MARK: - Pasting cells

    /// Pastes a grid of cells, or returns false for an ordinary paste.
    ///
    /// Into a table — the caret or a selection in one cell, or a block of
    /// cells selected — a grid fills the cells from the selection's top-left
    /// one, adding the rows and columns it needs, as one undoable edit. A single value over a
    /// selected block fills every cell of it. Anywhere else, only Edmund's own
    /// cells paste specially, as a new table; a spreadsheet's tab-separated
    /// text pastes as the text it is.
    ///
    /// A grid is Edmund's own clip, or text a spreadsheet marked as tabular,
    /// or plain text holding a tab. Text with no tab is not a grid: pasted
    /// into a cell, a word is a word.
    func pasteTableCells(from pasteboard: NSPasteboard) -> Bool {
        guard !rawTableEditing else { return false }
        let clip = pasteboard.data(forType: TableCellsClip.pasteboardType)
            .flatMap { try? JSONDecoder().decode(TableCellsClip.self, from: $0) }
        let target: (blockIndex: Int, row: Int, column: Int, block: TableCellBlock?)?
        if let block = tableClipBlock {
            target = (block.blockIndex, block.rows.lowerBound, block.columns.lowerBound, block)
        } else if let cell = activeTableCell,
                  selectedRange().upperBound <= cell.contentRange.upperBound {
            // A caret, or text selected inside the one cell: either way the
            // grid starts at that cell. Left to `insertTableFromClip`, a
            // selection here would get a new table spliced into the row.
            target = (cell.blockIndex, cell.row, cell.column, nil)
        } else {
            target = nil
        }
        guard let target else {
            guard let clip, !clip.cells.isEmpty else { return false }
            insertTableFromClip(clip)
            return true
        }
        let grid: [[String]]
        if let clip {
            grid = clip.cells
        } else if let tabular = pasteboard.string(forType: .tabularText) {
            grid = parseTSV(tabular).map { $0.map(tableCellEscaped) }
        } else if let text = pasteboard.string(forType: .string), text.contains("\t") {
            grid = parseTSV(text).map { $0.map(tableCellEscaped) }
        } else {
            return false
        }
        guard !grid.isEmpty, let lines = tableLines(blockIndex: target.blockIndex) else {
            return false
        }
        let fill = grid.count == 1 && grid[0].count == 1 ? target.block : nil
        let edited: [String]
        if let fill {
            edited = filledTableLines(lines, block: fill, with: grid[0][0])
        } else {
            edited = pastedTableLines(lines, grid: grid, row: target.row, column: target.column)
        }
        replaceTable(blockIndex: target.blockIndex, lines: edited)
        if let fill {
            selectTableCells(blockIndex: fill.blockIndex,
                             from: (fill.rows.lowerBound, fill.columns.lowerBound),
                             to: (fill.rows.upperBound, fill.columns.upperBound))
        } else {
            let width = grid.map(\.count).max() ?? 1
            let lastRow = EditorTextView.tableLine(
                logicalRow: EditorTextView.tableLogicalRow(line: target.row) + grid.count - 1)
            let end = (row: lastRow, column: target.column + width - 1)
            if end.row == target.row && end.column == target.column,
               let cell = tableCell(blockIndex: target.blockIndex, row: end.row, column: end.column) {
                // One value pasted at a caret: the caret goes after it, as an
                // ordinary paste would leave it.
                setSelectedRange(NSRange(location: tableCellTextRange(cell).upperBound, length: 0))
            } else {
                selectTableCells(blockIndex: target.blockIndex,
                                 from: (target.row, target.column), to: end)
            }
        }
        return true
    }

    /// A clip pasted outside any table: a new table on lines of its own, the
    /// clip's first row as its header.
    private func insertTableFromClip(_ clip: TableCellsClip) {
        let width = clip.cells.map(\.count).max() ?? 0
        guard width > 0 else { return }
        func row(_ cells: [String]) -> String {
            "| " + (0..<width).map { $0 < cells.count ? cells[$0] : "" }
                .joined(separator: " | ") + " |"
        }
        let separator = "| " + (0..<width).map {
            $0 < clip.aligns.count && !clip.aligns[$0].isEmpty ? clip.aligns[$0] : "---"
        }.joined(separator: " | ") + " |"
        var lines = [row(clip.cells[0]), separator]
        lines += clip.cells.dropFirst().map(row)
        let table = prettyAlignedTableLines(lines).joined(separator: "\n")

        // Blank lines either side. Before, so the line above stays a paragraph
        // of its own; after, because GFM carries a table on through any line
        // that follows it, pipes or not, until a blank one (spec example 202).
        let ns = rawSource as NSString
        let range = selectedRange()
        func isNewline(_ i: Int) -> Bool { i < 0 || i >= ns.length || ns.character(at: i) == 0x0A }
        let start = range.location, end = range.upperBound
        let lead = start == 0 ? "" : !isNewline(start - 1) ? "\n\n" : !isNewline(start - 2) ? "\n" : ""
        let trail = end == ns.length ? "" : !isNewline(end) ? "\n\n" : !isNewline(end + 1) ? "\n" : ""
        let caret = range.location + (lead as NSString).length + (table as NSString).length
        applyFormattingEdit(rawRange: range, replacement: lead + table + trail,
                            select: NSRange(location: caret, length: 0))
    }

    /// A cell's content without the padding the column added or the spaces the
    /// author typed around it.
    func tableCellText(_ cell: TableCellRef) -> String {
        (rawSource as NSString).substring(with: tableCellTextRange(cell))
    }

    /// Where that content lives. Empty — length zero, at the cell's start —
    /// for a cell holding nothing but padding.
    func tableCellTextRange(_ cell: TableCellRef) -> NSRange {
        let ns = rawSource as NSString
        var start = cell.contentRange.location
        var end = min(cell.contentRange.upperBound, ns.length)
        while end > start, ns.character(at: end - 1) == 0x20 { end -= 1 }
        while start < end, ns.character(at: start) == 0x20 { start += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// The selection a cell's contents deserve: its text, or — for a cell with
    /// none — a caret one space in, where typing keeps `|  |` padded as it
    /// fills. The range `selectCellText` installs, without the scrolling.
    func tableCellSelectionRange(_ cell: TableCellRef) -> NSRange {
        let text = tableCellTextRange(cell)
        guard text.length == 0 else { return text }
        let inset = min(cell.contentRange.location + 1, cell.contentRange.upperBound)
        return NSRange(location: inset, length: 0)
    }

    /// The selected cells as tab-separated rows.
    ///
    /// The separator row has no cells to look up, so it drops out of a block
    /// that spans the header rather than pasting as a row of dashes.
    private func tableSpreadsheetText(_ block: TableCellBlock) -> String {
        block.rows.compactMap { row -> String? in
            let cells = block.columns.compactMap { column in
                tableCell(blockIndex: block.blockIndex, row: row, column: column)
                    .map { tableCellText($0) }
            }
            return cells.isEmpty ? nil : cells.map(tsvField).joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// One field, quoted the way a spreadsheet expects if it carries a
    /// character that would otherwise end the field or the row. A markdown cell
    /// cannot contain a newline, but it can contain a tab.
    private func tsvField(_ text: String) -> String {
        guard text.contains("\t") || text.contains("\"") || text.contains("\n") else {
            return text
        }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
