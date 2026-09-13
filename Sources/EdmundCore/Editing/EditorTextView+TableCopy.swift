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

extension EditorTextView {

    /// Paste, then tidy the delimiters of any table the paste landed in.
    ///
    /// Markdown tolerates a table written without its outer pipes and without
    /// the spaces either side of the inner ones, and plenty of sources emit
    /// exactly that — so a pasted table renders, but the source underneath it
    /// reads nothing like the ones this editor writes. Only the delimiters are
    /// touched; the pasted text itself is never reflowed.
    public override func paste(_ sender: Any?) {
        // A list pasted into a list is rewritten first; see EditorTextView+ListPaste.
        if let adjusted = listAdjustedPasteText() {
            insertText(adjusted, replacementRange: selectedRange())
            return
        }
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
