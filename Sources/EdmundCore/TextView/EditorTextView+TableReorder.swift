import AppKit

// MARK: - Dragging a row or column to a new place
//
// After Notes: press on a row or column pill and drag, and the row or column
// lifts and follows the pointer along its axis while an accent bar marks where
// it would land. Letting go moves it there as one undoable edit.
//
// The pill's whole gesture is taken here, click included, because a press on a
// pill can turn out to be either: under a few points of movement it is a click
// (select the row or column, or, on a selected tab's chevron, open the menu),
// past that it is a drag. AppKit's tracking loop has nothing to select in the margin.
//
// Nothing is restyled while the drag is in flight. The table's grid is read
// once when it starts and every tick only repaints the lifted box and the bar,
// old and new — so a tick costs the same in a long document as in a short one.
// The move is spliced into the source only on mouse-up.

/// A row or column on its way to a new place.
struct TableReorderDrag {
    let axis: TableHandle.Axis
    let blockIndex: Int
    /// What is moving: line indices for rows, column indices for columns.
    let span: ClosedRange<Int>
    /// The cell the other axis's pill stays at once the move lands.
    let anchor: (row: Int, column: Int)
    /// The grid as it stood when the drag began; nothing edits the table
    /// until the drop, so it stays true for the whole gesture.
    let grid: TableGrid
    /// The box of what is moving, where it started.
    let box: NSRect
    /// Where it would land: in front of row or column `gap`, rows counted
    /// without the separator (see `movedTableRows`).
    var gap: Int
    /// How far the pointer has moved along the axis.
    var offset: CGFloat = 0
}

extension EditorTextView {

    /// How far a press on a pill has to travel before it is a drag, not a click.
    static let tableReorderDragThreshold: CGFloat = 3

    /// The row of the table counting without the separator (0 the header,
    /// 1 the first body row), from a line index, and back.
    static func tableLogicalRow(line: Int) -> Int { line == 0 ? 0 : line - 1 }
    static func tableLine(logicalRow: Int) -> Int { logicalRow == 0 ? 0 : logicalRow + 1 }

    /// Runs the whole gesture that starts on a pill. A click on a plain pill
    /// selects its row or column; a click on a selected tab's chevron, or a
    /// double click anywhere on it, opens its menu; a drag on either moves the
    /// row or column.
    func trackTablePill(_ handle: TableHandle, with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        guard let window else { return }
        let start = convert(event.locationInWindow, from: nil)
        var dragging = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            if !dragging {
                let point = convert(next.locationInWindow, from: nil)
                guard hypot(point.x - start.x, point.y - start.y)
                        >= Self.tableReorderDragThreshold else { continue }
                guard beginTableReorder(handle) else { break }
                dragging = true
            }
            autoscroll(with: next)
            // Converted after the autoscroll, which moves the view under a
            // pointer that stays put in the window.
            updateTableReorder(to: convert(next.locationInWindow, from: nil), from: start)
        }
        if dragging {
            finishTableReorder()
        } else if handle.selected {
            // A double click opens the menu wherever it lands; a single click
            // only on the chevron, with the menu hanging just under it.
            if event.clickCount >= 2 {
                showTableHandleMenu(handle)
            } else {
                let chevron = selectedTabChevronBox(handle)
                if chevron.contains(start) {
                    showTableHandleMenu(handle,
                                        at: NSPoint(x: chevron.minX, y: handle.rect.maxY))
                }
            }
        } else {
            selectTableAxis(for: handle)
        }
    }

    /// Lifts the handle's row or column: selects it if it was not already,
    /// and records what is moving. False when there is no grid to drag on.
    private func beginTableReorder(_ handle: TableHandle) -> Bool {
        if !handle.selected { selectTableAxis(for: handle) }
        // Layout forced: this is a mouse path, and selecting the row or column
        // can have just restyled the table (see `tableGrid`).
        guard let selection = tableAxisSelection,
              let grid = tableGrid(blockIndex: selection.block.blockIndex, ensuringLayout: true),
              let box = tableCellBlockBox(selection.block, grid: grid) else { return false }
        let gap = selection.axis == .row
            ? Self.tableLogicalRow(line: selection.span.lowerBound)
            : selection.span.lowerBound
        tableReorderDrag = TableReorderDrag(
            axis: selection.axis, blockIndex: selection.block.blockIndex,
            span: selection.span, anchor: (selection.anchorRow, selection.anchorColumn),
            grid: grid, box: box, gap: gap)
        return true
    }

    /// Follows the pointer: the lifted box slides along the axis and the bar
    /// moves to the gap nearest the pointer. Repaints only where either was and
    /// is now.
    private func updateTableReorder(to point: NSPoint, from start: NSPoint) {
        guard var drag = tableReorderDrag else { return }
        let before = tableReorderDirtyRect(drag)
        drag.offset = drag.axis == .row ? point.y - start.y : point.x - start.x
        drag.gap = tableReorderGap(drag, at: point)
        tableReorderDrag = drag
        setNeedsDisplay(before)
        setNeedsDisplay(tableReorderDirtyRect(drag))
    }

    /// Drops the row or column at its gap, as one undoable edit, and selects
    /// it where it landed. A drop where it started changes nothing.
    private func finishTableReorder() {
        guard let drag = tableReorderDrag else { return }
        tableReorderDrag = nil
        setNeedsDisplay(tableReorderDirtyRect(drag))
        guard let lines = tableLines(blockIndex: drag.blockIndex) else { return }
        switch drag.axis {
        case .row:
            let top = Self.tableLogicalRow(line: drag.span.lowerBound)
            let rows = top...Self.tableLogicalRow(line: drag.span.upperBound)
            guard let moved = movedTableRows(lines, from: rows, to: drag.gap) else { return }
            replaceTable(blockIndex: drag.blockIndex, lines: moved)
            let first = drag.gap > rows.upperBound ? drag.gap - rows.count : drag.gap
            let firstLine = Self.tableLine(logicalRow: first)
            let span = firstLine...Self.tableLine(logicalRow: first + rows.count - 1)
            selectTableAxis(.row, blockIndex: drag.blockIndex, span: span,
                            anchor: (span.lowerBound, drag.anchor.column))
        case .column:
            let columns = drag.span
            guard let moved = movedTableColumns(lines, from: columns, to: drag.gap) else { return }
            replaceTable(blockIndex: drag.blockIndex, lines: moved)
            let first = drag.gap > columns.upperBound ? drag.gap - columns.count : drag.gap
            selectTableAxis(.column, blockIndex: drag.blockIndex,
                            span: first...(first + columns.count - 1),
                            anchor: (drag.anchor.row, first))
        }
    }

    /// The gap nearest the pointer: rows or columns whose middle the pointer
    /// has passed go before it.
    private func tableReorderGap(_ drag: TableReorderDrag, at point: NSPoint) -> Int {
        let grid = drag.grid
        switch drag.axis {
        case .row:
            let lines = grid.rows.indices.filter { $0 != 1 }
            return lines.filter { grid.rows[$0].midY < point.y }.count
        case .column:
            return (0..<grid.columns).filter {
                (grid.columnEdges[$0] + grid.columnEdges[$0 + 1]) / 2 < point.x
            }.count
        }
    }

    /// The accent bar marking the gap: across the table between two rows, or
    /// down it between two columns.
    func tableReorderBar(_ drag: TableReorderDrag) -> NSRect? {
        let grid = drag.grid
        // No bar where a drop would change nothing: either side of the run.
        let moving = drag.axis == .row
            ? Self.tableLogicalRow(line: drag.span.lowerBound)
                ... Self.tableLogicalRow(line: drag.span.upperBound)
            : drag.span
        guard drag.gap < moving.lowerBound || drag.gap > moving.upperBound + 1,
              let bounds = grid.bounds else { return nil }
        let thickness = 3 * tableChromeScale
        switch drag.axis {
        case .row:
            let lines = grid.rows.indices.filter { $0 != 1 }
            guard !lines.isEmpty else { return nil }
            let y: CGFloat
            if drag.gap <= 0 {
                y = grid.rows[lines[0]].minY
            } else if drag.gap >= lines.count {
                y = grid.rows[lines[lines.count - 1]].maxY
            } else {
                // Between two rows — across the separator strip, for the gap
                // under the header — so the bar lands on the line between them.
                y = (grid.rows[lines[drag.gap - 1]].maxY + grid.rows[lines[drag.gap]].minY) / 2
            }
            return NSRect(x: bounds.minX, y: y - thickness / 2,
                          width: bounds.width, height: thickness)
        case .column:
            let edge = min(max(0, drag.gap), grid.columnEdges.count - 1)
            return NSRect(x: grid.columnEdges[edge] - thickness / 2, y: bounds.minY,
                          width: thickness, height: bounds.height)
        }
    }

    /// The lifted box: the moving row or column, slid along its axis with the
    /// pointer.
    func tableReorderLiftedBox(_ drag: TableReorderDrag) -> NSRect {
        drag.axis == .row ? drag.box.offsetBy(dx: 0, dy: drag.offset)
                          : drag.box.offsetBy(dx: drag.offset, dy: 0)
    }

    /// Everything a drag tick can have drawn: the lifted box, the bar, and the
    /// tab, which is drawn over the box's start and may have to come back.
    private func tableReorderDirtyRect(_ drag: TableReorderDrag) -> NSRect {
        var rect = tableReorderLiftedBox(drag).insetBy(dx: -4, dy: -4)
        if let bar = tableReorderBar(drag) { rect = rect.union(bar.insetBy(dx: -2, dy: -2)) }
        return rect
    }

    /// Draws a drag in flight. Called from `drawTableHandles`, on the
    /// background pass with the rest of the table chrome.
    func drawTableReorder(in dirty: NSRect) {
        guard let drag = tableReorderDrag else { return }
        let lifted = tableReorderLiftedBox(drag)
        if lifted.intersects(dirty) {
            accentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(rect: lifted).fill()
            accentColor.withAlphaComponent(0.6).setStroke()
            let outline = NSBezierPath(rect: lifted)
            outline.lineWidth = 2
            outline.stroke()
        }
        if let bar = tableReorderBar(drag), bar.intersects(dirty) {
            accentColor.setFill()
            let radius = min(bar.width, bar.height) / 2
            NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
        }
    }
}
