import AppKit

// MARK: - Locating a table cell in the document
//
// The renderer splits a table into rows and cells on every restyle
// (`styleTableSpan`) and throws the split away again, so nothing in the editor
// can answer "which cell is this offset in?". The popup cell editor needs
// exactly that, in *document* coordinates: `cellRanges(in:)` is line-local and
// takes no document context, and `blockIndexForRawOffset` stops at the block.

/// One cell of one table, located in the document.
public struct TableCellRef: Equatable {
    let blockIndex: Int
    /// Line index within the table block. 0 is the header, 1 the separator.
    let row: Int
    /// Column index as `cellRanges(in:)` counts them — which skips a cell with
    /// no characters at all (`||`), the same way the renderer's own column
    /// numbering does. A cell holding just a space still counts.
    let column: Int
    /// Document range of the cell's content, pipes excluded, surrounding
    /// spaces included.
    let contentRange: NSRange
}

extension EditorTextView {

    /// The table cell containing `rawOffset`, or nil if the offset isn't in a
    /// table's content rows.
    ///
    /// The separator row returns nil: it renders as a 4pt strip of hidden text,
    /// so a click there is never a request to edit it.
    func tableCell(atRawOffset rawOffset: Int) -> TableCellRef? {
        // `blockIndexForRawOffset` clamps past the end rather than failing, so
        // the offset has to be checked against the block it hands back.
        guard let blockIndex = blockIndexForRawOffset(rawOffset),
              blockIndex < blocks.count else { return nil }
        let block = blocks[blockIndex]
        guard block.kind == .table,
              rawOffset >= block.range.location,
              rawOffset <= block.range.upperBound else { return nil }

        let local = rawOffset - block.range.location
        var lineStart = 0
        for (row, line) in block.content.components(separatedBy: "\n").enumerated() {
            let lineNS = line as NSString
            let lineEnd = lineStart + lineNS.length
            guard local <= lineEnd else {
                lineStart = lineEnd + 1   // past the newline
                continue
            }
            guard row != 1 else { return nil }

            let cells = cellRanges(in: lineNS)
            guard !cells.isEmpty else { return nil }
            // A pipe is shared: it closes one cell and opens the next. It goes
            // to the *next* one (`<`, not `<=`), which lands a click correctly
            // whatever the column alignment. A right- or center-aligned column
            // hangs its padding kern on the pipe that precedes it, so that pipe
            // covers real screen width and must belong to the cell it pads; a
            // left-aligned column pads a character inside itself instead, and
            // its own pipe is left zero-width and unclickable. Past the last
            // cell (a click on the row's closing pipe) clamps to that cell.
            let hit = cells.firstIndex { local - lineStart < $0.end } ?? cells.count - 1
            let cell = cells[hit]
            return TableCellRef(
                blockIndex: blockIndex, row: row, column: hit,
                contentRange: NSRange(
                    location: block.range.location + lineStart + cell.start,
                    length: cell.end - cell.start))
        }
        return nil
    }

    /// Re-resolves a cell by position rather than by range.
    ///
    /// Ranges shift the moment a commit changes a cell's length, so moving from
    /// one cell to the next has to name the target by where it sits in the
    /// table, not by the offsets that were valid before the write.
    func tableCell(blockIndex: Int, row: Int, column: Int) -> TableCellRef? {
        guard blockIndex < blocks.count, blocks[blockIndex].kind == .table else { return nil }
        let block = blocks[blockIndex]
        let lines = block.content.components(separatedBy: "\n")
        guard row >= 0, row < lines.count, row != 1 else { return nil }
        var lineStart = 0
        for (i, line) in lines.enumerated() {
            let lineNS = line as NSString
            if i == row {
                let cells = cellRanges(in: lineNS)
                guard column >= 0, column < cells.count else { return nil }
                let cell = cells[column]
                return TableCellRef(
                    blockIndex: blockIndex, row: row, column: column,
                    contentRange: NSRange(location: block.range.location + lineStart + cell.start,
                                          length: cell.end - cell.start))
            }
            lineStart += lineNS.length + 1
        }
        return nil
    }
}
