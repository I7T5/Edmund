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
        for handle in tableHandles() where handle.rect.intersects(dirty) {
            let hovered = handle == hoveredTableHandle
            // Space, not a border, per the editor's chrome idiom — but a handle
            // has to read as a target with no text beside it to anchor on, so it
            // keeps a hairline outline and gains a fill only under the pointer.
            let body = NSBezierPath(roundedRect: handle.rect,
                                    xRadius: Self.tableHandleRadius,
                                    yRadius: Self.tableHandleRadius)
            (hovered ? NSColor.quaternaryLabelColor : NSColor.clear).setFill()
            body.fill()
            tableChromeLineColor.setStroke()
            // One device pixel, like the column borders it hangs off: a 1pt
            // stroke reads as twice their weight on a Retina display.
            body.lineWidth = 1 / (window?.backingScaleFactor ?? 1)
            body.stroke()
            drawHandleDots(handle)
        }
    }

    /// Three dots along the pill's long axis, in the same gray as its outline —
    /// the pill is chrome that should recede until it is looked for.
    private func drawHandleDots(_ handle: TableHandle) {
        let size: CGFloat = 1.5
        let spacing: CGFloat = 4
        tableChromeLineColor.setFill()
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
    func tableCellPosition(at point: NSPoint, blockIndex: Int) -> (row: Int, column: Int)? {
        guard let grid = tableGrid(blockIndex: blockIndex), !grid.rows.isEmpty,
              grid.columns > 0 else { return nil }
        var row = grid.rows.firstIndex { point.y < $0.maxY } ?? grid.rows.count - 1
        if row == 1 { row = point.y < grid.rows[1].midY ? 0 : 2 }
        row = min(max(0, row), grid.rows.count - 1)
        let edge = grid.columnEdges.firstIndex { point.x < $0 } ?? grid.columnEdges.count
        return (row, min(max(0, edge - 1), grid.columns - 1))
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
    /// costs nothing.
    private func handleHitBox(_ rect: NSRect) -> NSRect { rect.insetBy(dx: -6, dy: -6) }

    func tableHandleHit(at event: NSEvent) -> TableHandle? {
        let point = convert(event.locationInWindow, from: nil)
        return tableHandles().first { handleHitBox($0.rect).contains(point) }
    }

    /// Recomputes which handle the pointer is over. Called from `mouseMoved`
    /// beside the `</>` button's own hover tracking.
    func updateTableHandleHover(at point: NSPoint) {
        let hit = tableHandles().first { handleHitBox($0.rect).contains(point) }
        guard hit != hoveredTableHandle else { return }
        if let old = hoveredTableHandle { setNeedsDisplay(handleHitBox(old.rect)) }
        if let hit { setNeedsDisplay(handleHitBox(hit.rect)) }
        hoveredTableHandle = hit
    }

    /// Repaints the bands the handles live in. Called on every caret move, since
    /// the handles follow the active cell and nothing else invalidates them.
    func invalidateTableHandles() {
        let bands = tableHandles().map { handleHitBox($0.rect) } + lastTableHandleBands
        for band in bands { setNeedsDisplay(band) }
        lastTableHandleBands = tableHandles().map { handleHitBox($0.rect) }
    }

    // MARK: - Menus

    /// The menu a handle opens.
    func tableHandleMenu(_ handle: TableHandle) -> NSMenu {
        let menu = NSMenu()
        // Every item's enablement is decided by the operation's own guard, so
        // AppKit must not second-guess it: auto-enabling asks the responder
        // chain to validate a selector it does not know and greys the lot.
        menu.autoenablesItems = false
        switch handle.axis {
        case .row:
            addTableItems(to: menu, blockIndex: handle.blockIndex,
                          row: handle.row, column: handle.column, axis: .row)
        case .column:
            addTableItems(to: menu, blockIndex: handle.blockIndex,
                          row: handle.row, column: handle.column, axis: .column)
        }
        menu.addItem(.separator())
        let raw = NSMenuItem(title: "Edit as Markdown",
                             action: #selector(editTableAsMarkdown(_:)), keyEquivalent: "")
        raw.target = self
        raw.representedObject = handle.blockIndex
        menu.addItem(raw)
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
            item("Delete Row", TableOperation(.deleteRow, blockIndex, row, column),
                 enabled: canDeleteTableRow(blockIndex: blockIndex, row: row))
        }
        if axis == nil { menu.addItem(.separator()) }
        if axis != .row {
            item("Add Column Before", TableOperation(.insertColumn, blockIndex, row, column))
            item("Add Column After", TableOperation(.insertColumn, blockIndex, row, column + 1))
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

    @objc func editTableAsMarkdown(_ sender: NSMenuItem) {
        guard let blockIndex = sender.representedObject as? Int else { return }
        activateRawTableEditing(blockIndex: blockIndex)
    }

    /// Opens a handle's menu at the pill.
    func showTableHandleMenu(_ handle: TableHandle, with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        tableHandleMenu(handle).popUp(positioning: nil,
                                      at: NSPoint(x: handle.rect.minX, y: handle.rect.maxY),
                                      in: self)
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
            out += " box.x=\(box.minX)...\(box.maxX)"
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

    private func debugMouseEvent(at point: NSPoint) -> NSEvent? {
        guard let window else { return nil }
        return NSEvent.mouseEvent(with: .leftMouseDown, location: convert(point, to: nil),
                                  modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil,
                                  eventNumber: 0, clickCount: 1, pressure: 1)
    }
}
#endif
