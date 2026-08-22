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

extension EditorTextView {

    /// The pill's short side, its long side, and the air between it and the
    /// table. `tableHandleBand` is the room the header row has to reserve above
    /// itself for the column pill to have somewhere to be.
    static let tableHandleThickness: CGFloat = 12
    static let tableHandleLength: CGFloat = 26
    static let tableHandleGap: CGFloat = 4
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
    func tableHandles() -> [TableHandle] {
        guard let cell = activeTableCell,
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

    /// Draws the handles and, while a context menu is up, the outline around the
    /// cell it belongs to. Called from `drawBackground(in:)`.
    func drawTableHandles(in dirty: NSRect) {
        drawTableMenuCellOutline(in: dirty)
        for handle in tableHandles() where handle.rect.intersects(dirty) {
            let hovered = handle == hoveredTableHandle
            // Space, not a border, per the editor's chrome idiom — but a handle
            // has to read as a target with no text beside it to anchor on, so it
            // keeps a hairline outline and gains a fill only under the pointer.
            let body = NSBezierPath(roundedRect: handle.rect,
                                    xRadius: handle.rect.height.rounded() / 2,
                                    yRadius: handle.rect.width.rounded() / 2)
            (hovered ? NSColor.quaternaryLabelColor : NSColor.clear).setFill()
            body.fill()
            tableChromeLineColor.setStroke()
            body.lineWidth = 1
            body.stroke()
            drawHandleDots(handle)
        }
    }

    /// Three dots along the pill's long axis.
    private func drawHandleDots(_ handle: TableHandle) {
        let size: CGFloat = 2
        let spacing: CGFloat = 5
        syntaxDimColor.setFill()
        for step in -1...1 {
            let offset = CGFloat(step) * spacing
            let center = handle.axis == .column
                ? CGPoint(x: handle.rect.midX + offset, y: handle.rect.midY)
                : CGPoint(x: handle.rect.midX, y: handle.rect.midY + offset)
            NSBezierPath(ovalIn: NSRect(x: center.x - size / 2, y: center.y - size / 2,
                                        width: size, height: size)).fill()
        }
    }

    /// The cell a context menu is currently acting on, outlined so the menu's
    /// "this row"/"this column" is unambiguous. The box comes from the grid
    /// rather than from the cell's text segments, so an overflowing cell
    /// outlines its column and not the hidden characters underneath it.
    private func drawTableMenuCellOutline(in dirty: NSRect) {
        guard let cell = tableMenuCell,
              let grid = tableGrid(blockIndex: cell.blockIndex),
              let box = grid.cellRect(row: cell.row, column: cell.column),
              box.intersects(dirty) else { return }
        accentColor.setStroke()
        let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 3, yRadius: 3)
        path.lineWidth = 1.5
        path.stroke()
    }

    /// `chromeLineColor` lives on the fragment's extension and is private there;
    /// the handles want the same gray so a pill reads as part of the same grid
    /// as the borders it hangs off.
    private var tableChromeLineColor: NSColor {
        NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? EditorTextView.darkRuleGray : NSColor.separatorColor
    }

    // MARK: - Pointer

    /// A generous hit box: the pill is small chrome in empty space, so the slack
    /// costs nothing.
    private func handleHitBox(_ rect: NSRect) -> NSRect { rect.insetBy(dx: -4, dy: -4) }

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

    /// Opens a handle's menu at the pill, and outlines the cell it acts on for
    /// as long as the menu is up.
    func showTableHandleMenu(_ handle: TableHandle, with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        tableMenuCell = tableCell(blockIndex: handle.blockIndex,
                                  row: handle.row, column: handle.column)
        needsDisplay = true
        let menu = tableHandleMenu(handle)
        menu.delegate = self
        menu.popUp(positioning: nil,
                   at: NSPoint(x: handle.rect.minX, y: handle.rect.maxY), in: self)
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

extension EditorTextView: NSMenuDelegate {
    /// The cell outline belongs to the menu, so it goes when the menu does.
    public func menuDidClose(_ menu: NSMenu) {
        guard tableMenuCell != nil else { return }
        tableMenuCell = nil
        needsDisplay = true
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
        let report = "cell=\(String(describing: tableMenuCell)) items=\(menu.items.map(\.title))"
        menu.popUp(positioning: nil, at: point, in: self)
        return report
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
