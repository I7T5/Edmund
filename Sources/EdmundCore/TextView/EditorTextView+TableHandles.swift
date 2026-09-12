import AppKit

// MARK: - Table row and column handles
//
// Two small ⋯ pills, after Apple Notes (misc/frontend-refs/notes-table-controls.png):
// one lying above the active column, one standing to the left of the active row.
// Clicking either opens a menu of add/delete operations for that row or column.
//
// "Active" means the caret's cell, not the pointer's. A handle you can only see
// while hovering is one you have to already know about; a handle that appears
// the moment you click into a table is on screen exactly when the operations it
// offers make sense. It follows the caret from cell to cell.
//
// Both hang outside the table — the column pill in a band the header row
// reserves above itself (`tableHandleBand`, held clear of the column borders by
// the `.tableRow` decoration's `topInset`), the row pill in the left margin the
// line numbers use. They draw on the background pass beside the numbers and the
// `</>` button, which is also why they never disturb the text: that margin and
// that band are space the text never occupies.
//
// This file also draws the other piece of table chrome, the box around a
// multi-cell selection — see "Cell selection" below.

/// Which handle, and what it acts on. The row and column indices are the ones
/// the operations in EditorTextView+TableStructure take.
struct TableHandle: Equatable {
    enum Axis { case row, column }
    let axis: Axis
    let blockIndex: Int
    let row: Int
    let column: Int
    let rect: NSRect
}

/// A rectangular run of cells in one table.
struct TableCellBlock: Equatable {
    let blockIndex: Int
    let rows: ClosedRange<Int>
    let columns: ClosedRange<Int>
}

extension EditorTextView {

    /// The pill's short side, its long side, and the air between it and the
    /// table. `tableHandleBand` is the room the header row has to reserve above
    /// itself for the column pill to have somewhere to be.
    ///
    /// Measured off the Notes reference at 2×: a 32×16 px pill, 8 px clear of
    /// the table, with a 3 px corner — a rounded rectangle, not a capsule.
    static let tableHandleThickness: CGFloat = 8
    static let tableHandleLength: CGFloat = 16
    static let tableHandleGap: CGFloat = 4
    static let tableHandleRadius: CGFloat = 1.5
    static var tableHandleBand: CGFloat { tableHandleThickness + tableHandleGap }

    /// Ink for the pill's outline and its dots, as alpha on the label colour.
    ///
    /// Absolute, not a multiple of the table's own border: our grid is drawn far
    /// lighter than Notes' (230/255 gray against its 190), so weighting the pill
    /// against ours is what made it vanish. Notes puts its pill outline at 230
    /// and its dots at 170 — and since the pill has to carry itself here without
    /// a darker grid behind it, both go a step past that.
    static let tableHandleOutlineAlpha: CGFloat = 0.22
    static let tableHandleDotAlpha: CGFloat = 0.45

    // MARK: - What the handles point at

    /// The cell the caret is in, if it is in a table that is currently rendered.
    /// Nil while the table shows its raw markdown — the pipes are visible then
    /// and there is no grid to hang a handle off.
    var activeTableCell: TableCellRef? {
        guard !rawTableEditing else { return nil }
        return tableCell(atRawOffset: selectedRange().location)
    }

    /// The row and column pills for the active cell, in view coordinates.
    ///
    /// None while a block of cells is selected: the pills point at one row and
    /// one column, which is not what is selected then, and Notes takes them off
    /// screen for the same reason. The selection box is the affordance.
    func tableHandles() -> [TableHandle] {
        guard tableCellSelection == nil, let cell = activeTableCell,
              let grid = tableGrid(blockIndex: cell.blockIndex),
              grid.rows.indices.contains(cell.row),
              let cellRect = grid.cellRect(row: cell.row, column: cell.column),
              let top = grid.rows.first?.minY else { return [] }

        let rowRect = grid.rows[cell.row]
        let thickness = Self.tableHandleThickness
        let length = Self.tableHandleLength
        let gap = Self.tableHandleGap

        // Clamped so a narrow window pins the row pill to the view's edge
        // rather than sliding it off the left.
        let rowX = max(0, (grid.columnEdges.first ?? 0) - gap - thickness)
        let row = TableHandle(
            axis: .row, blockIndex: cell.blockIndex, row: cell.row, column: cell.column,
            rect: NSRect(x: rowX, y: rowRect.midY - length / 2,
                         width: thickness, height: min(length, rowRect.height)))
        let column = TableHandle(
            axis: .column, blockIndex: cell.blockIndex, row: cell.row, column: cell.column,
            rect: NSRect(x: cellRect.midX - length / 2, y: top - gap - thickness,
                         width: length, height: thickness))
        return [row, column]
    }

    // MARK: - Drawing

    /// Draws the handles and the box around a multi-cell selection. Called from
    /// `drawBackground(in:)`.
    func drawTableHandles(in dirty: NSRect) {
        drawTableCellSelection(in: dirty)
        let handles = tableHandles()
        // Where the pills are *on screen*, which is the only thing the next
        // caret move can repaint away. `invalidateTableHandles` cannot be
        // trusted to record it: it runs before the restyle a click triggers,
        // and a grid that is briefly unavailable makes it record nothing at
        // all — after which the pill it forgot outlives its own move.
        lastTableHandleBands = handles.map { handleHitBox($0) }
        for handle in handles where handle.rect.intersects(dirty) {
            let hovered = handle == hoveredTableHandle
            // Space, not a border, per the editor's chrome idiom — but a handle
            // has to read as a target with no text beside it to anchor on, so it
            // keeps a hairline outline and gains a fill only under the pointer.
            let body = NSBezierPath(roundedRect: handle.rect,
                                    xRadius: Self.tableHandleRadius,
                                    yRadius: Self.tableHandleRadius)
            (hovered ? NSColor.quaternaryLabelColor : NSColor.clear).setFill()
            body.fill()
            tableHandleInk(Self.tableHandleOutlineAlpha).setStroke()
            // One device pixel, like the column borders it hangs off: a 1pt
            // stroke reads as twice their weight on a Retina display.
            body.lineWidth = 1 / (window?.backingScaleFactor ?? 1)
            body.stroke()
            drawHandleDots(handle)
        }
    }

    /// The pill's ink. `labelColor` rather than the grid's gray so it inverts
    /// with the appearance: on a dark background the pill has to lighten, not
    /// darken.
    private func tableHandleInk(_ alpha: CGFloat) -> NSColor {
        NSColor.labelColor.withAlphaComponent(alpha)
    }

    /// Three dots along the pill's long axis, carrying the pill on their own —
    /// its outline is a hint of a box, not a border.
    private func drawHandleDots(_ handle: TableHandle) {
        let size: CGFloat = 1.5
        let spacing: CGFloat = 4
        tableHandleInk(Self.tableHandleDotAlpha).setFill()
        for step in -1...1 {
            let offset = CGFloat(step) * spacing
            let center = handle.axis == .column
                ? CGPoint(x: handle.rect.midX + offset, y: handle.rect.midY)
                : CGPoint(x: handle.rect.midX, y: handle.rect.midY + offset)
            NSBezierPath(ovalIn: NSRect(x: center.x - size / 2, y: center.y - size / 2,
                                        width: size, height: size)).fill()
        }
    }

    /// `chromeLineColor` lives on the fragment's extension and is private there;
    /// the handles want the same gray so a pill reads as part of the same grid
    /// as the borders it hangs off.
    private var tableChromeLineColor: NSColor {
        NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? EditorTextView.darkRuleGray : NSColor.separatorColor
    }

    // MARK: - Cell selection
    //
    // A drag across cells selects whole cells, and is drawn as one square-
    // cornered box around them rather than as a text highlight. Two reasons,
    // both visible in the "before" screenshot: a text highlight runs to the
    // *text container's* right edge on every line it fully covers, which in a
    // table means a band hanging hundreds of points past the table's own edge;
    // and a highlight that stops mid-cell doesn't say which cells a Copy will
    // take. The box says exactly that, and the two dots on its corners drag it
    // wider.
    //
    // The bleed is why the selection is installed as *one range per row* rather
    // than as a single span: AppKit runs a highlight to the container's edge
    // only on a line the selection covers through its newline, so a range that
    // stops at the row's last selected cell never triggers it. That also makes
    // the highlight cover exactly the columns the box is drawn around, and
    // there is nothing left to suppress — `selectedTextAttributes` would not
    // have been enough anyway, since AppKit ignores it for the unemphasized
    // highlight it draws while the window is not key.

    /// The block of cells the selection covers, when it covers more than one
    /// cell of a single rendered table.
    var tableCellSelection: TableCellBlock? { tableCellBlock(forRanges: selectedRanges) }

    /// The block a set of selection ranges covers — the ranges as they are
    /// about to be installed, which is what the highlight decision needs.
    func tableCellBlock(forRanges ranges: [NSValue]) -> TableCellBlock? {
        let spans = ranges.map(\.rangeValue)
        guard let first = spans.first, let last = spans.last,
              last.upperBound > 0 else { return nil }
        return tableCellBlock(from: first.location, to: last.upperBound - 1)
    }

    /// Switches AppKit's text highlight off while a block of cells is selected.
    /// Notes drops the text selection entirely at that point — the box is the
    /// only marker — and a highlight here would say the wrong thing anyway,
    /// since what is selected is cells, not a run of characters.
    func setTableCellHighlight(suppressed: Bool) {
        guard suppressed != tableCellHighlightSuppressed else { return }
        // Read before the swap, never inside the ternary: the stored default is
        // lazy, and evaluating it on the restoring call would capture the
        // cleared attributes as "the default" and lose the highlight for good.
        let restore = defaultSelectedTextAttributes
        tableCellHighlightSuppressed = suppressed
        selectedTextAttributes = suppressed ? [.backgroundColor: NSColor.clear] : restore
    }

    /// The block of cells a range covers, when it covers more than one cell of
    /// a single rendered table.
    func tableCellBlock(for range: NSRange) -> TableCellBlock? {
        guard range.length > 0 else { return nil }
        return tableCellBlock(from: range.location, to: range.upperBound - 1)
    }

    private func tableCellBlock(from: Int, to: Int) -> TableCellBlock? {
        // A pipe belongs to the cell it opens, so a selection that reaches just
        // past a cell's padding would otherwise read as spanning two cells and
        // swallow the neighbour whole. The delimiter closing a cell counts as
        // that cell's own end.
        var to = to
        let ns = rawSource as NSString
        if to > from, to < ns.length, ns.character(at: to) == 0x7C { to -= 1 }
        guard to >= from, !rawTableEditing,
              let start = tableCell(atRawOffset: from),
              let end = tableCell(atRawOffset: to),
              start.blockIndex == end.blockIndex,
              start.row != end.row || start.column != end.column else { return nil }
        return TableCellBlock(blockIndex: start.blockIndex,
                              rows: min(start.row, end.row)...max(start.row, end.row),
                              columns: min(start.column, end.column)...max(start.column, end.column))
    }

    /// One range per row of the block, each running from the row's first
    /// selected cell to its last — never over the newline that ends the row.
    /// The separator row holds no cells and simply contributes none.
    func tableCellSelectionRanges(_ block: TableCellBlock) -> [NSValue] {
        block.rows.compactMap { row in
            guard let first = tableCell(blockIndex: block.blockIndex, row: row,
                                        column: block.columns.lowerBound),
                  let last = tableCell(blockIndex: block.blockIndex, row: row,
                                       column: block.columns.upperBound) else { return nil }
            return NSValue(range: NSRange(
                location: first.contentRange.location,
                length: last.contentRange.upperBound - first.contentRange.location))
        }
    }

    /// The box a cell selection is drawn in, in view coordinates.
    func tableCellSelectionBox() -> NSRect? {
        guard let block = tableCellSelection,
              let grid = tableGrid(blockIndex: block.blockIndex),
              let first = grid.cellRect(row: block.rows.lowerBound,
                                        column: block.columns.lowerBound),
              let last = grid.cellRect(row: block.rows.upperBound,
                                       column: block.columns.upperBound) else { return nil }
        return first.union(last)
    }

    private func drawTableCellSelection(in dirty: NSRect) {
        guard let box = tableCellSelectionBox(), box.intersects(dirty) else { return }
        // Square corners, and the stroke centred on the box's own edge rather
        // than inset within it: the box stands *on* the cell borders, so it
        // reads as those borders thickening rather than as a second rectangle
        // drawn just inside them. A radius would leave a gap at every corner it
        // shares with them.
        accentColor.setStroke()
        let path = NSBezierPath(rect: box)
        path.lineWidth = 2
        path.stroke()
        accentColor.setFill()
        for point in tableCellSelectionDots(box) {
            NSBezierPath(ovalIn: NSRect(x: point.x - Self.tableCellDotRadius,
                                        y: point.y - Self.tableCellDotRadius,
                                        width: Self.tableCellDotRadius * 2,
                                        height: Self.tableCellDotRadius * 2)).fill()
        }
    }

    /// 7.5pt across, measured off the Notes recording at 2x (a 15px blob on a
    /// 4px stroke).
    static let tableCellDotRadius: CGFloat = 3.75

    /// The two drag dots: top-left and bottom-right of the box, the corners
    /// Notes puts them on — centred on the corner itself, where the two lines
    /// of the box cross.
    private func tableCellSelectionDots(_ box: NSRect) -> [NSPoint] {
        [NSPoint(x: box.minX, y: box.minY), NSPoint(x: box.maxX, y: box.maxY)]
    }

    /// The cell a drag from one of the dots should hold fixed — the corner
    /// opposite the one grabbed — or nil if the point is on neither dot.
    func tableCellSelectionAnchor(at point: NSPoint)
        -> (block: TableCellBlock, anchor: (row: Int, column: Int))? {
        guard let block = tableCellSelection, let box = tableCellSelectionBox() else { return nil }
        let dots = tableCellSelectionDots(box)
        let slack = Self.tableCellDotRadius + 4
        if NSRect(x: dots[0].x - slack, y: dots[0].y - slack,
                  width: slack * 2, height: slack * 2).contains(point) {
            return (block, (block.rows.upperBound, block.columns.upperBound))
        }
        if NSRect(x: dots[1].x - slack, y: dots[1].y - slack,
                  width: slack * 2, height: slack * 2).contains(point) {
            return (block, (block.rows.lowerBound, block.columns.lowerBound))
        }
        return nil
    }

    /// Runs the drag started on a selection dot. AppKit's own tracking loop
    /// would anchor on the click point and start a fresh selection, so this
    /// takes the gesture whole and keeps the opposite corner fixed.
    func trackTableCellSelection(from anchor: (row: Int, column: Int), blockIndex: Int) {
        guard let window else { return }
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { break }
            let point = convert(event.locationInWindow, from: nil)
            guard let now = tableCellPosition(at: point, blockIndex: blockIndex) else { continue }
            selectTableCells(blockIndex: blockIndex, from: anchor, to: now)
        }
    }

    /// The cell of `blockIndex` under a view point, clamped into the table so a
    /// drag that wanders outside it still extends to the nearest edge. Never
    /// the separator row, which holds no text to select.
    func tableCellPosition(at point: NSPoint, blockIndex: Int,
                           ensuringLayout: Bool = false) -> (row: Int, column: Int)? {
        guard let grid = tableGrid(blockIndex: blockIndex, ensuringLayout: ensuringLayout),
              !grid.rows.isEmpty,
              grid.columns > 0 else { return nil }
        var row = grid.rows.firstIndex { point.y < $0.maxY } ?? grid.rows.count - 1
        if row == 1 { row = point.y < grid.rows[1].midY ? 0 : 2 }
        row = min(max(0, row), grid.rows.count - 1)
        let edge = grid.columnEdges.firstIndex { point.x < $0 } ?? grid.columnEdges.count
        return (row, min(max(0, edge - 1), grid.columns - 1))
    }

    /// The cell a point lands in, judged by the drawn grid rather than by the
    /// character underneath it. The grid is the only authority on which cell
    /// the user aimed at: a cell's padding is a single kerned glyph, and AppKit
    /// splits that glyph's advance down the middle, so the far half of a cell's
    /// pad hit-tests as the *next* cell's first character.
    func tableCell(at point: NSPoint) -> TableCellRef? {
        for (i, block) in blocks.enumerated() where block.kind == .table {
            // Layout forced: this runs on the click paths, and the click has
            // just restyled the block it landed in. See `tableGrid`.
            guard let grid = tableGrid(blockIndex: i, ensuringLayout: true),
                  let bounds = grid.bounds,
                  bounds.contains(point),
                  let position = tableCellPosition(at: point, blockIndex: i,
                                                   ensuringLayout: true) else { continue }
            return tableCell(blockIndex: i, row: position.row, column: position.column)
        }
        return nil
    }

    /// Where a click at `point` should leave the caret, or nil to keep the
    /// offset AppKit chose.
    ///
    /// Two corrections, in order. First the offset is pulled back into the cell
    /// the click actually landed in — AppKit's midpoint rule on a pad glyph
    /// hundreds of points wide can otherwise carry it clean over a drawn
    /// border into the next cell, which no click inside a cell should ever do.
    /// Then it comes back to the text, as below.
    func tableCellCaretSnap(at point: NSPoint, offset: Int) -> Int? {
        guard !rawTableEditing else { return nil }
        guard let cell = tableCell(at: point) else { return tableCellCaretSnap(offset) }
        let clamped = min(max(offset, cell.contentRange.location), cell.contentRange.upperBound)
        let snapped = tableCellCaretSnap(clamped) ?? clamped
        return snapped == offset ? nil : snapped
    }

    /// Where a click that landed in a cell's trailing padding should really put
    /// the caret, or nil when it landed on the text already.
    ///
    /// A column pads its cells by hanging a `.kern` on the cell's last
    /// character, so that one space can be hundreds of points wide. AppKit
    /// hit-tests it like any other glyph: click past its midpoint and the caret
    /// goes to the far side, which draws it out in the middle of the empty part
    /// of the cell rather than against the text it belongs to. Landing one
    /// space in from the end also means typing fills the cell without eating
    /// the space before its closing pipe.
    ///
    /// Click-only, deliberately: it would trap a Right-arrow that is legitimately
    /// walking out of the cell.
    func tableCellCaretSnap(_ offset: Int) -> Int? {
        guard !rawTableEditing else { return nil }
        // A pipe belongs to the cell it *opens*, so an offset sitting at one
        // cell's very end resolves to the next one. Step back a character to
        // get the cell whose padding the caret is really standing in.
        var found = tableCell(atRawOffset: offset)
        if found.map({ offset < $0.contentRange.location }) ?? true, offset > 0 {
            found = tableCell(atRawOffset: offset - 1)
        }
        guard let cell = found,
              offset >= cell.contentRange.location,
              offset <= cell.contentRange.upperBound else { return nil }
        let ns = rawSource as NSString
        var textEnd = cell.contentRange.upperBound
        while textEnd > cell.contentRange.location, ns.character(at: textEnd - 1) == 0x20 {
            textEnd -= 1
        }
        // An all-blank cell keeps one space, the same rule `selectCellText` uses.
        let target = max(textEnd, min(cell.contentRange.location + 1,
                                      cell.contentRange.upperBound))
        return offset > target ? target : nil
    }

    /// Whether a double-click's selection is worth keeping. It is only worth
    /// keeping if it is text belonging to the cell the click landed in.
    ///
    /// A double-click in a cell's padding has no word to take: the pad is one
    /// kerned space, and beside it sits the row's hidden pipe. AppKit selects
    /// one of those, and a one-character selection of an invisible glyph draws
    /// exactly like a caret stranded in the middle of the cell — while a ⌘C
    /// then copies a delimiter. Neither is a selection the user asked for.
    func tableCellSelectionIsJunk(_ selection: NSRange, at point: NSPoint) -> Bool {
        guard selection.length > 0, !rawTableEditing,
              let cell = tableCell(at: point) else { return false }
        if selection.location < cell.contentRange.location
            || selection.upperBound > cell.contentRange.upperBound { return true }
        return (rawSource as NSString).substring(with: selection)
            .allSatisfy { $0 == " " || $0 == "|" }
    }

    /// Where a caret that has come to rest on a table's hidden pipe should go
    /// instead, or nil when it is resting somewhere legitimate.
    ///
    /// A pipe is drawn clear and at a hidden font, and it carries half of its
    /// column's padding as kern — so a caret sitting on one appears to float in
    /// the very middle of the cell's blank space, and typing there lands
    /// outside any cell's content. No caret should ever rest there, whatever
    /// put it there: a click, an arrow, or a selection AppKit fixed up after an
    /// edit. Which way it was heading decides where it goes — backwards to the
    /// text it just left, forwards to the text it was reaching for — so this
    /// never traps an arrow key mid-row.
    /// The caret positions a cell allows: from just before its first visible
    /// character to just after its last. An all-blank cell keeps a single
    /// position one space in, the rule `selectCellText` uses so typing keeps
    /// `|  |` padded as it fills.
    func tableCellLiveRange(_ cell: TableCellRef) -> (lower: Int, upper: Int) {
        let text = tableCellTextRange(cell)
        guard text.length > 0 else {
            let p = min(cell.contentRange.location + 1, cell.contentRange.upperBound)
            return (p, p)
        }
        return (text.location, text.upperBound)
    }

    /// Where a caret at `offset` should really rest, or nil when it is already
    /// on a cell's text. A caret must never sit in the padding a row keeps
    /// around its pipes, nor on a pipe — before *or* after it — whatever put it
    /// there: a click, an arrow, or a selection AppKit fixed up after an edit.
    ///
    /// A click lands on the text of the cell it hit: the point already chose the
    /// cell, so a pad position snaps to that cell's near edge and never crosses
    /// into a neighbour. An arrow has a direction — `previous` is where the
    /// caret came from — so a pad position moves the way the caret was heading,
    /// to the next cell's text going forward or the previous cell's going back,
    /// stepping over the dead run of pad, pipe and pad in one press.
    func tableCellCaretResting(_ offset: Int, from previous: Int) -> Int? {
        guard !rawTableEditing, offset >= 0,
              let cell = tableCell(atRawOffset: offset) else { return nil }
        let live = tableCellLiveRange(cell)
        if offset >= live.lower && offset <= live.upper { return nil }
        let isClick = tableClickPoint != nil
        let forward = previous <= offset
        if offset < live.lower {
            // Leading pad, or the pipe that opens this cell.
            if isClick || forward { return live.lower }
            if let prev = tableCell(blockIndex: cell.blockIndex, row: cell.row,
                                    column: cell.column - 1) {
                return tableCellLiveRange(prev).upper
            }
            return live.lower
        }
        // Trailing pad, or the pipe that closes this cell.
        if isClick || !forward { return live.upper }
        if let next = tableCell(blockIndex: cell.blockIndex, row: cell.row,
                                column: cell.column + 1) {
            return tableCellLiveRange(next).lower
        }
        return live.upper
    }

    /// The cell a click landed in without landing on its text, or nil when it
    /// landed on the text or outside a table.
    ///
    /// The cell comes from the grid when the grid can supply one, and from the
    /// offset AppKit hit when it cannot. That fallback is not belt-and-braces:
    /// in a real document the grid lookup returns nothing for the block under
    /// the pointer often enough that it cannot be the only route, while the
    /// offset route demonstrably resolves the same pad correctly — it is what
    /// the caret correction has been running on all along.
    ///
    /// Then "did it land on the text": an offset outside the cell's text is out
    /// in the padding, whichever side. An offset inside it is on the text
    /// unless the pointer is past the text's drawn box, which catches the pad
    /// glyph AppKit rounds back onto the last character.
    func tableCellEmptySpace(at point: NSPoint, hit: Int?) -> TableCellRef? {
        guard !rawTableEditing,
              let cell = tableCell(at: point) ?? hit.flatMap(tableCellHoldingOffset)
        else { return nil }
        let text = tableCellTextRange(cell)
        guard let hit, hit >= text.location, hit < text.upperBound else { return cell }
        guard let box = tableCellTextBox(text) else { return nil }
        return point.x > box.maxX + 1 ? cell : nil
    }

    /// Why the grid did or did not resolve a cell for a point — named rather
    /// than inferred, because a log of a real click could not say otherwise and
    /// a synthesised one does not reproduce the failure. Read under the verbose
    /// trace; every branch is a guard in `tableGrid` or `tableCell(at:)`.
    func tableGridDiagnostic(at point: NSPoint, hit: Int?) -> String {
        guard let hit, let index = blockIndexForRawOffset(hit) else { return "noBlock" }
        guard index < blocks.count else { return "badIndex" }
        guard blocks[index].kind == .table else { return "notTable" }
        guard let grid = tableGrid(blockIndex: index) else { return "noGrid" }
        guard let bounds = grid.bounds else { return "noBounds" }
        guard bounds.contains(point) else {
            return "outside(x\(Int(bounds.minX))-\(Int(bounds.maxX))"
                + ",y\(Int(bounds.minY))-\(Int(bounds.maxY)))"
        }
        guard let position = tableCellPosition(at: point, blockIndex: index) else {
            return "noPosition(rows\(grid.rows.count),cols\(grid.columns))"
        }
        return tableCell(blockIndex: index, row: position.row, column: position.column) == nil
            ? "noCell(r\(position.row)c\(position.column))"
            : "ok(r\(position.row)c\(position.column))"
    }

    /// The cell an offset stands in, padding included. A pipe belongs to the
    /// cell it *opens*, so an offset sitting at one cell's very end resolves to
    /// the next one — step back a character to get the cell whose padding the
    /// pointer is really in. The same rule `tableCellCaretSnap` uses.
    private func tableCellHoldingOffset(_ offset: Int) -> TableCellRef? {
        var found = tableCell(atRawOffset: offset)
        if found.map({ offset < $0.contentRange.location }) ?? true, offset > 0 {
            found = tableCell(atRawOffset: offset - 1)
        }
        guard let cell = found, offset >= cell.contentRange.location,
              offset <= cell.contentRange.upperBound else { return nil }
        return cell
    }

    /// The drawn box of a range, in view coordinates, or nil when it has no
    /// laid-out extent.
    private func tableCellTextBox(_ range: NSRange) -> NSRect? {
        guard range.length > 0, let tlm = textLayoutManager,
              let from = tlm.location(tlm.documentRange.location, offsetBy: range.location),
              let to = tlm.location(tlm.documentRange.location, offsetBy: range.upperBound),
              let textRange = NSTextRange(location: from, end: to) else { return nil }
        let origin = textContainerOrigin
        var box: NSRect?
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            let rect = frame.offsetBy(dx: origin.x, dy: origin.y)
            box = box.map { $0.union(rect) } ?? rect
            return true
        }
        return box
    }

    /// A selection trimmed to the text of the cell it lies in, or nil when it
    /// is already clean or is not a single cell's selection.
    ///
    /// Dragging across a cell's padding sweeps up the pad's kerned space and
    /// the row's hidden pipe: invisible characters, so the highlight looks like
    /// it covers blank space, and a ⌘C takes a delimiter into the clipboard.
    /// A selection that spans cells is not this — the block logic turns that
    /// into whole cells — so only a selection inside one cell is trimmed.
    func tableCellSelectionTrimmed(_ range: NSRange) -> NSRange? {
        guard range.length > 0, !rawTableEditing,
              tableCellBlock(for: range) == nil,
              let cell = tableCell(atRawOffset: range.location) else { return nil }
        let ns = rawSource as NSString
        var start = max(range.location, cell.contentRange.location)
        var end = min(range.upperBound, cell.contentRange.upperBound)
        // The pad is trailing spaces; the pipe is already outside `contentRange`.
        while end > start, ns.character(at: end - 1) == 0x20 { end -= 1 }
        while start < end, ns.character(at: start) == 0x20 { start += 1 }
        let trimmed = NSRange(location: start, length: max(0, end - start))
        return trimmed == range ? nil : trimmed
    }

    /// The block a drag from one point to another covers, or nil when the drag
    /// has not left the cell it started in and is an ordinary text selection.
    ///
    /// Geometry, not offsets. A selection's character range is linear, so a
    /// diagonal drag runs through everything between its two ends — drag from
    /// a header cell down into the row below and the range sweeps the whole
    /// rest of the header on its way, which read as "the header row, every
    /// column" and flashed the box out to the table's full width before it
    /// settled. Two points name two cells, and the rectangle between them is
    /// the only thing a drag across a grid can mean.
    func tableCellBlock(fromPoint: NSPoint, toPoint: NSPoint) -> TableCellBlock? {
        guard !rawTableEditing, let anchor = tableCell(at: fromPoint),
              let start = tableCellPosition(at: fromPoint, blockIndex: anchor.blockIndex),
              let end = tableCellPosition(at: toPoint, blockIndex: anchor.blockIndex),
              start != end else { return nil }
        return TableCellBlock(
            blockIndex: anchor.blockIndex,
            rows: min(start.row, end.row)...max(start.row, end.row),
            columns: min(start.column, end.column)...max(start.column, end.column))
    }

    /// Selects every cell between two positions.
    func selectTableCells(blockIndex: Int,
                          from: (row: Int, column: Int), to: (row: Int, column: Int)) {
        let block = TableCellBlock(
            blockIndex: blockIndex,
            rows: min(from.row, to.row)...max(from.row, to.row),
            columns: min(from.column, to.column)...max(from.column, to.column))
        let ranges = tableCellSelectionRanges(block)
        guard !ranges.isEmpty else { return }
        setSelectedRanges(ranges, affinity: .downstream, stillSelecting: false)
    }

    /// Repaints when a cell selection appears, changes or goes. Called on every
    /// selection change, drag ticks included.
    ///
    /// It repaints the whole view rather than the box's band, and keys off the
    /// selection rather than off `tableCellSelectionBox()`, because the box
    /// needs the grid and the grid needs laid-out fragments — which the block
    /// does not have at the instant the selection changes and restyles it. A
    /// box invalidated from a nil rect never repaints, and what reaches the
    /// screen is whatever slice of it some later, unrelated repaint happens to
    /// cover.
    func updateTableCellSelectionChrome() {
        let active = tableCellSelection != nil
        guard active || tableCellSelectionWasActive else { return }
        tableCellSelectionWasActive = active
        needsDisplay = true
    }

    // MARK: - Pointer

    /// A generous hit box: the pill is small chrome in empty space, so the slack
    /// costs nothing — except on the side facing the table, where it would
    /// cost a click. The pill sits `tableHandleGap` clear of the table, so
    /// slack wider than the gap reaches into the first column (or the header
    /// row), and a click a couple of points inside a narrow column would open
    /// the pill's menu instead of putting the caret in the cell it landed in.
    func handleHitBox(_ handle: TableHandle) -> NSRect {
        var box = handle.rect.insetBy(dx: -6, dy: -6)
        switch handle.axis {
        case .row:
            box.size.width = handle.rect.maxX + Self.tableHandleGap - box.minX
        case .column:
            // Flipped coordinates: the table is below the column pill.
            box.size.height = handle.rect.maxY + Self.tableHandleGap - box.minY
        }
        return box
    }

    func tableHandleHit(at event: NSEvent) -> TableHandle? {
        let point = convert(event.locationInWindow, from: nil)
        return tableHandles().first { handleHitBox($0).contains(point) }
    }

    /// Recomputes which handle the pointer is over. Called from `mouseMoved`
    /// beside the `</>` button's own hover tracking.
    func updateTableHandleHover(at point: NSPoint) {
        let hit = tableHandles().first { handleHitBox($0).contains(point) }
        guard hit != hoveredTableHandle else { return }
        if let old = hoveredTableHandle { setNeedsDisplay(handleHitBox(old)) }
        if let hit { setNeedsDisplay(handleHitBox(hit)) }
        hoveredTableHandle = hit
    }

    /// Repaints the bands the handles live in — where they are going and where
    /// they have been. Called on every caret move, since the handles follow the
    /// active cell and nothing else invalidates them.
    ///
    /// It does not record anything: `drawTableHandles` is the one writer of
    /// `lastTableHandleBands`, because only a draw knows what actually reached
    /// the screen.
    func invalidateTableHandles() {
        for band in tableHandles().map({ handleHitBox($0) }) + lastTableHandleBands {
            setNeedsDisplay(band)
        }
    }

    // MARK: - Menus

    /// The menu a handle opens.
    func tableHandleMenu(_ handle: TableHandle) -> NSMenu {
        let menu = NSMenu()
        // Every item's enablement is decided by the operation's own guard, so
        // AppKit must not second-guess it: auto-enabling asks the responder
        // chain to validate a selector it does not know and greys the lot.
        menu.autoenablesItems = false
        // Nothing may add to this menu but the operations below. It carried an
        // "Edit as Markdown" item until the `</>` button became reachable while
        // a cell is being edited, which is a better home for the same command.
        menu.allowsContextMenuPlugIns = false
        switch handle.axis {
        case .row:
            addTableItems(to: menu, blockIndex: handle.blockIndex,
                          row: handle.row, column: handle.column, axis: .row)
        case .column:
            addTableItems(to: menu, blockIndex: handle.blockIndex,
                          row: handle.row, column: handle.column, axis: .column)
        }
        return menu
    }

    /// Row and/or column operations for one cell. `axis` nil gives both, which
    /// is what the cell context menu wants.
    func addTableItems(to menu: NSMenu, blockIndex: Int, row: Int, column: Int,
                       axis: TableHandle.Axis?) {
        func item(_ title: String, _ op: TableOperation, enabled: Bool = true) {
            let entry = NSMenuItem(title: title,
                                   action: #selector(performTableOperation(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.representedObject = op
            entry.isEnabled = enabled
            menu.addItem(entry)
        }
        if axis != .column {
            // Row 1 is the separator and is never a handle's row, so the only
            // row that cannot take one above it is none.
            item("Add Row Above", TableOperation(.insertRow, blockIndex, row, column))
            item("Add Row Below", TableOperation(.insertRow, blockIndex,
                                                 row == 0 ? 2 : row + 1, column))
            // A divider sets the destructive Delete apart from the two adds.
            menu.addItem(.separator())
            item("Delete Row", TableOperation(.deleteRow, blockIndex, row, column),
                 enabled: canDeleteTableRow(blockIndex: blockIndex, row: row))
        }
        if axis == nil { menu.addItem(.separator()) }
        if axis != .row {
            item("Add Column Before", TableOperation(.insertColumn, blockIndex, row, column))
            item("Add Column After", TableOperation(.insertColumn, blockIndex, row, column + 1))
            menu.addItem(.separator())
            item("Delete Column", TableOperation(.deleteColumn, blockIndex, row, column),
                 enabled: canDeleteTableColumn(blockIndex: blockIndex, column: column))
        }
    }

    @objc func performTableOperation(_ sender: NSMenuItem) {
        guard let op = sender.representedObject as? TableOperation else { return }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        switch op.kind {
        case .insertRow:
            insertTableRow(blockIndex: op.blockIndex, at: op.row, column: op.column)
        case .deleteRow:
            deleteTableRow(blockIndex: op.blockIndex, row: op.row, column: op.column)
        case .insertColumn:
            insertTableColumn(blockIndex: op.blockIndex, at: op.column, row: op.row)
        case .deleteColumn:
            deleteTableColumn(blockIndex: op.blockIndex, column: op.column, row: op.row)
        }
    }

    /// Opens a handle's menu at the pill.
    func showTableHandleMenu(_ handle: TableHandle, with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        // Popped with no view, in screen coordinates. A menu shown *in* a text
        // view is handed to the text system on its way to the screen, which
        // adds AutoFill and Shortcuts entries of its own — reasonable in a text
        // field's context menu, meaningless in a list of table operations. With
        // no view there is nothing in the chain left to contribute them.
        let corner = NSPoint(x: handle.rect.minX, y: handle.rect.maxY)
        let onScreen = window?.convertPoint(toScreen: convert(corner, to: nil)) ?? corner
        tableHandleMenu(handle).popUp(positioning: nil, at: onScreen, in: nil)
    }
}

/// One add/delete, carried on the menu item that performs it.
final class TableOperation: NSObject {
    enum Kind { case insertRow, deleteRow, insertColumn, deleteColumn }
    let kind: Kind
    let blockIndex: Int
    let row: Int
    let column: Int

    init(_ kind: Kind, _ blockIndex: Int, _ row: Int, _ column: Int) {
        self.kind = kind
        self.blockIndex = blockIndex
        self.row = row
        self.column = column
    }
}

#if DEBUG
extension EditorTextView {

    /// Harness hooks (ReproScript). Both drive the menus the way a click does —
    /// the handle one through its own hit test, the cell one through
    /// `menu(for:)` — so a screenshot shows what a user would get rather than
    /// what the menu builders would produce in isolation. `popUp` runs its own
    /// event loop, so these do not return until the menu is dismissed.
    /// Snapshots a menu's items once it is actually on screen, then dismisses
    /// it. Anything the text system contributes is added as the menu is
    /// displayed, so a menu that has only been *built* proves nothing.
    private final class MenuProbe: NSObject, NSMenuDelegate {
        var titles: [String] = []
        func menuWillOpen(_ menu: NSMenu) {
            DispatchQueue.main.async {
                self.titles = menu.items.map(\.title)
                menu.cancelTracking()
            }
        }
    }

    /// Pops a handle's menu and reports what was on it while it was open.
    public func debugTableHandleMenuItems(column wantsColumn: Bool) -> String {
        let axis: TableHandle.Axis = wantsColumn ? .column : .row
        guard let handle = tableHandles().first(where: { $0.axis == axis }) else {
            return "no \(wantsColumn ? "column" : "row") handle"
        }
        let menu = tableHandleMenu(handle)
        let probe = MenuProbe()
        menu.delegate = probe
        let corner = NSPoint(x: handle.rect.minX, y: handle.rect.maxY)
        let onScreen = window?.convertPoint(toScreen: convert(corner, to: nil)) ?? corner
        menu.popUp(positioning: nil, at: onScreen, in: nil)
        return "items=\(probe.titles)"
    }

    public func debugOpenTableHandleMenu(column wantsColumn: Bool) -> String {
        let axis: TableHandle.Axis = wantsColumn ? .column : .row
        guard let handle = tableHandles().first(where: { $0.axis == axis }),
              let event = debugMouseEvent(at: NSPoint(x: handle.rect.midX,
                                                      y: handle.rect.midY)) else {
            return "no \(wantsColumn ? "column" : "row") handle"
        }
        guard let hit = tableHandleHit(at: event) else {
            return "handle missed its own hit box at \(handle.rect)"
        }
        let report = "rect=\(hit.rect) row=\(hit.row) col=\(hit.column)"
        showTableHandleMenu(hit, with: event)
        return report
    }

    public func debugOpenTableCellMenu(needle: String) -> String {
        let range = (rawSource as NSString).range(of: needle)
        guard range.location != NSNotFound, let window else { return "no \(needle)" }
        var actual = NSRange()
        let onScreen = firstRect(forCharacterRange: NSRange(location: range.location, length: 0),
                                 actualRange: &actual)
        let point = convert(window.convertPoint(fromScreen: CGPoint(x: onScreen.midX,
                                                                    y: onScreen.midY)), from: nil)
        guard let event = debugMouseEvent(at: point), let menu = menu(for: event) else {
            return "no menu at \(point)"
        }
        let report = "sel=\(selectedRange()) items=\(menu.items.map(\.title))"
        menu.popUp(positioning: nil, at: point, in: self)
        return report
    }

    /// Selects a block of cells the way a drag across them would, so a
    /// screenshot can show the selection box without synthesizing a drag.
    public func debugSelectTableCells(fromRow: Int, fromColumn: Int,
                                      toRow: Int, toColumn: Int) -> String {
        guard let blockIndex = blocks.firstIndex(where: { $0.kind == .table }) else {
            return "no table"
        }
        selectTableCells(blockIndex: blockIndex,
                         from: (fromRow, fromColumn), to: (toRow, toColumn))
        return "ranges=\(selectedRanges.map(\.rangeValue))"
            + " box=\(String(describing: tableCellSelectionBox()))"
    }

    /// Where the caret lands for every offset in the cell holding `needle`,
    /// beside the cell's own box — so a caret that draws away from the text it
    /// should sit against shows up as a number rather than as a squint.
    public func debugCaretPositions(needle: String) -> String {
        let ns = rawSource as NSString
        let found = ns.range(of: needle)
        guard found.location != NSNotFound,
              let cell = tableCell(atRawOffset: found.location) else { return "no \(needle)" }
        var out = "sel=\(selectedRange()) cell=\(cell.contentRange)"
        if let grid = tableGrid(blockIndex: cell.blockIndex),
           let box = grid.cellRect(row: cell.row, column: cell.column) {
            out += " box.x=\(box.minX)...\(box.maxX) box.y=\(box.minY)...\(box.maxY)"
        }
        for offset in cell.contentRange.location...cell.contentRange.upperBound {
            var actual = NSRange()
            let rect = firstRect(forCharacterRange: NSRange(location: offset, length: 0),
                                 actualRange: &actual)
            let point = window.map { convert($0.convertPoint(fromScreen: rect.origin), from: nil) }
            let char = offset < ns.length ? ns.substring(with: NSRange(location: offset, length: 1))
                                          : "EOF"
            out += " | \(offset)'\(char == "\n" ? "\\n" : char)'x=\(point.map { Int($0.x) } ?? -1)"
        }
        return out
    }

    /// Forces the hover state the `</>` button is revealed by, so a screenshot
    /// can show it without the pointer being parked on the table.
    public func debugHoverTable() -> String {
        guard let blockIndex = blocks.firstIndex(where: { $0.kind == .table }) else {
            return "no table"
        }
        hoveredTableBlock = blockIndex
        needsDisplay = true
        return "revealed=\(tableRawButtonIsRevealed(blockIndex: blockIndex))"
            + " boxes=\(revealedTableRawButtons().map(\.rect))"
    }

    /// Runs a real ⌘C and reports what landed on the pasteboard, then puts back
    /// whatever was there before. The harness runs on someone's own machine;
    /// taking their clipboard to check a feature is not a fair trade.
    public func debugCopyProbe() -> String {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        copy(nil)
        let copied = pasteboard.string(forType: .string) ?? "<nothing>"
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
        return "sel=\(selectedRanges.map(\.rangeValue)) copied="
            + copied.replacingOccurrences(of: "\t", with: "<TAB>")
                .replacingOccurrences(of: "\n", with: "<NL>")
    }

    /// Clicks at a view point through the real `mouseDown` path and reports
    /// what each stage of it decided. CGEvent clicks do not land in the harness
    /// environment, so the mouse-up is posted to the window's queue first and
    /// `mouseDown` is then called directly: `super.mouseDown` runs its own
    /// tracking loop and finds that up event, so the whole gesture — hit test,
    /// AppKit's own caret placement, the wrapped-cell override, the pad snap —
    /// runs exactly as it would for a user.
    public func debugClickProbe(x: CGFloat, y: CGFloat, clicks: Int = 1) -> String {
        let point = NSPoint(x: x, y: y)
        guard let window,
              let down = debugMouseEvent(at: point, clicks: clicks) else { return "no window" }
        let hit = clickCharIndex(at: down)
        let wrapped = wrappedCellCharIndex(at: down)
        var out = "point=(\(Int(x)),\(Int(y))) clicks=\(clicks)"
            + " hit=\(hit.map(String.init) ?? "nil")"
            + " wrapped=\(wrapped.map(String.init) ?? "nil")"
        if let hit {
            out += " snap(hit)=\(tableCellCaretSnap(hit).map(String.init) ?? "nil")"
            if let cell = tableCell(atRawOffset: hit) {
                out += " cell=r\(cell.row)c\(cell.column)\(cell.contentRange)"
            }
        }
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: convert(point, to: nil),
                                    modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil,
                                    eventNumber: 0, clickCount: clicks, pressure: 0)
        if let up { window.postEvent(up, atStart: false) }
        mouseDown(with: down)
        let sel = selectedRange()
        out += " -> sel=\(sel) raw=\(rawTableEditing ? "Y" : "N")"
        var actual = NSRange()
        let screen = firstRect(forCharacterRange: NSRange(location: sel.location, length: 0),
                               actualRange: &actual)
        let appkit = convert(window.convertPoint(fromScreen: screen.origin), from: nil)
        out += " appkitCaretX=\(Int(appkit.x))"
        if let wrappedRect = wrappedCellCaretRect() {
            out += " wrappedCaretX=\(Int(wrappedRect.minX))"
        }
        return out
    }

    /// Clicks every cell of every table at five points across its width and
    /// reports only what came out wrong: a caret that left the cell it was
    /// clicked in, or one that stopped short of the cell's text when the click
    /// landed past that text. One run answers "does clicking into a cell put
    /// the caret where it should" for the whole document.
    public func debugClickAudit(rows wanted: ClosedRange<Int>? = nil) -> String {
        var lines: [String] = []
        var checked = 0
        for (index, block) in blocks.enumerated() where block.kind == .table {
            guard let grid = tableGrid(blockIndex: index) else { continue }
            for row in grid.rows.indices where row != 1
                && (wanted?.contains(row) ?? true) {
                for column in 0..<grid.columns {
                    guard let box = grid.cellRect(row: row, column: column),
                          let cell = tableCell(blockIndex: index, row: row, column: column)
                    else { continue }
                    let target = tableCellCaretSnap(cell.contentRange.upperBound)
                        ?? cell.contentRange.upperBound
                    let textEnd = caretRect(target)
                    for fraction in [0.04, 0.25, 0.5, 0.75, 0.96] as [CGFloat] {
                        let point = NSPoint(x: box.minX + box.width * fraction, y: box.midY)

                        // Only meaningful on the text's own visual line: a
                        // wrapped cell's earlier lines are all "past" the last
                        // line's caret in x while being ordinary text.
                        let onTextLine = point.y >= textEnd.minY && point.y <= textEnd.maxY
                        let pastText = onTextLine && point.x > textEnd.maxX + 1
                        for clicks in [1, 2] {
                            guard click(at: point, clicks: clicks) else { continue }
                            checked += 1
                            let selection = selectedRange()
                            let got = selection.location
                            let inCell = got >= cell.contentRange.location
                                && selection.upperBound <= cell.contentRange.upperBound
                            let what = "r\(row)c\(column) f\(fraction) x\(clicks)"
                            if !inCell {
                                lines.append("\(what) LEFT THE CELL"
                                    + " sel=\(selection) cell=\(cell.contentRange)")
                            } else if tableCellSelectionIsJunk(selection, at: point) {
                                lines.append("\(what) SELECTED PAD sel=\(selection)")
                            } else if pastText && selection.length == 0 && got != target {
                                lines.append("\(what) SHORT OF THE TEXT"
                                    + " sel=\(got) want=\(target)")
                            }
                        }
                    }
                }
            }
        }
        return "checked=\(checked) failures=\(lines.count)"
            + (lines.isEmpty ? "" : "\n  " + lines.joined(separator: "\n  "))
    }

    /// The caret's rect for an offset, in view coordinates.
    private func caretRect(_ offset: Int) -> NSRect {
        guard let window else { return .zero }
        var actual = NSRange()
        let screen = firstRect(forCharacterRange: NSRange(location: offset, length: 0),
                               actualRange: &actual)
        let origin = convert(window.convertPoint(fromScreen: screen.origin), from: nil)
        return NSRect(x: origin.x, y: origin.y, width: screen.width, height: screen.height)
    }

    /// A real click at a view point: the mouse-up goes on the window's queue
    /// first so `super.mouseDown`'s own tracking loop finds it, and the whole
    /// gesture then runs exactly as it would for a user. CGEvent clicks do not
    /// land in the harness environment, which is why this exists.
    @discardableResult
    private func click(at point: NSPoint, clicks: Int = 1) -> Bool {
        guard let window, let down = debugMouseEvent(at: point, clicks: clicks) else { return false }
        // A pill's hit box is generous enough to reach a couple of points into
        // a narrow first column, and its menu runs its own event loop — which
        // would hang the audit rather than fail it. Checked here rather than
        // once per point: the pills follow the caret, so the click before this
        // one can have moved a pill onto the very point about to be clicked.
        if tableHandleHit(at: down) != nil { return false }
        if tableCellSelectionAnchor(at: point) != nil { return false }

        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: convert(point, to: nil),
                                    modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil,
                                    eventNumber: 0, clickCount: clicks, pressure: 0)
        if let up { window.postEvent(up, atStart: false) }
        mouseDown(with: down)
        // If the tracking loop did not consume the up, it would be picked up by
        // the next gesture's loop — which is how a stale up carrying another
        // click count turns the next single click into a word selection.
        NSApp.discardEvents(matching: .any, before: nil)
        return true
    }

    /// Every table row's decoration flags beside the fragment they are drawn
    /// against, so a missing grid line can be read off as a number: whether the
    /// row asked for a bottom border at all, and where that border would land.
    public func debugTableRules() -> String {
        guard let tlm = textLayoutManager, let storage = textStorage else { return "no layout" }
        var out: [String] = []
        for (index, block) in blocks.enumerated() where block.kind == .table {
            out.append("table block \(index) range=\(block.range)")
            let ns = rawSource as NSString
            var line = 0
            var offset = block.range.location
            while offset < block.range.upperBound {
                let lineRange = ns.lineRange(for: NSRange(location: offset, length: 0))
                var flags = "no decoration"
                if let decoration = storage.attribute(.blockDecoration, at: offset,
                                                      effectiveRange: nil) as? BlockDecoration,
                   case .tableRow(_, _, _, let separator, let bottomBorder,
                                  let topInset) = decoration.kind {
                    flags = "sep=\(separator ? "Y" : "N") bottom=\(bottomBorder ? "Y" : "N")"
                        + " topInset=\(topInset)"
                }
                var geometry = "no fragment"
                if let location = tlm.location(tlm.documentRange.location, offsetBy: offset),
                   let fragment = tlm.textLayoutFragment(for: location) {
                    let frame = fragment.layoutFragmentFrame
                    geometry = "y=\(frame.minY) h=\(frame.height)"
                        + " ruleAt=\(frame.minY + frame.height)"
                }
                out.append("  line \(line) \(flags) \(geometry)")
                line += 1
                offset = lineRange.upperBound
            }
        }
        return out.joined(separator: "\n")
    }

    private func debugMouseEvent(at point: NSPoint, clicks: Int = 1) -> NSEvent? {
        guard let window else { return nil }
        return NSEvent.mouseEvent(with: .leftMouseDown, location: convert(point, to: nil),
                                  modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil,
                                  eventNumber: 0, clickCount: clicks, pressure: 1)
    }
}
#endif
