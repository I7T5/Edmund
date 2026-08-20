import AppKit

// MARK: - Popup table-cell editor
//
// Clicking a rendered table cell opens its markdown in a card hanging off that
// cell's row: a row wide, top edge on the row's bottom, arrow on the cell. The panel has its own layout and its own text storage, which is what
// makes it worth the trouble:
//
//   - A cell that overflows its column is drawn from a detached scratch layout
//     (`.tableCellWraps`), so a caret in the host storage cannot follow the
//     glyphs the reader sees.
//   - A cell's structural pipes are hidden zero-width glyphs, so caret motion
//     across them has to be hand-built.
//   - IME composition would land on the document's own storage, which is the
//     delete-drift bug class (ARCHITECTURE §8).
//
// None of those apply to a separate text view. Write-back is then one
// contiguous range replacement through `applyFormattingEdit`, the same
// primitive the Format menu uses.
//
// It is deliberately *not* an NSPopover. A popover centres its body on its
// positioning rect, so the body always travels with the arrow — and the whole
// point here is the opposite: the card is a row wide and holds still while only
// the arrow slides to the column being edited. Owning the drawing also means
// the same class serves the attached and the torn-off states.
//
// The panel is a child window of the document window, so it follows the window
// for free; only scrolling and resizing need repositioning by hand.

extension EditorTextView {

    /// Smallest the popup is allowed to be, so a narrow table still gets a
    /// usable field.
    static let cellEditorMinWidth: CGFloat = 220

    /// Air between the row's bottom edge and the arrow's tip. Zero: the arrow
    /// should touch the row it points at.
    private static let cellEditorGap: CGFloat = 0

    /// How far the card travels as it appears, and how long over. The exit is
    /// the same motion run backwards.
    private static let cellEditorTravel: CGFloat = 6
    private static let cellEditorFade: TimeInterval = 0.12

    // MARK: - Geometry

    /// The on-screen rect of a cell's content (view coordinates).
    ///
    /// The cell's characters are all present in storage — hiding a delimiter is
    /// attribute-only — so its own text segments give the rect, and no column
    /// geometry has to be persisted out of `styleTableSpan` for this. That holds
    /// for an overflowing cell too: its characters are hidden but its trailing
    /// character carries a `.kern` of the column's full slack, so the segments
    /// still span the column.
    ///
    /// Approximately, though: TextKit 2 splits the gap a kern opens between the
    /// segments either side of it, so the edges land mid-padding rather than on
    /// the pipe. Good enough for the vertical anchor and for centring the arrow
    /// on an empty cell, which is all this is used for — anything that has to
    /// agree with the column the reader sees measures the glyphs instead, via
    /// `tableCellTextCenterX`.
    func tableCellRect(for cell: TableCellRef) -> NSRect? {
        guard let tlm = textLayoutManager,
              let range = blockTextRange(columnRange(of: cell), tlm) else { return nil }
        return unionOfSegments(in: range, tlm)
    }

    /// The cell's range widened to take in the pipe that opens it.
    ///
    /// That pipe is where a right- or centre-aligned column hangs the kern that
    /// gives the column its width — the same reason `tableCell(atRawOffset:)`
    /// gives a pipe to the cell after it. Measuring the content alone therefore
    /// comes up short of the column the reader sees.
    private func columnRange(of cell: TableCellRef) -> NSRange {
        let ns = rawSource as NSString
        guard cell.contentRange.location > 0,
              ns.character(at: cell.contentRange.location - 1) == 0x7C else {
            return cell.contentRange
        }
        return NSRange(location: cell.contentRange.location - 1,
                       length: cell.contentRange.length + 1)
    }

    /// The on-screen rect of a whole table (view coordinates).
    func tableRect(blockIndex: Int) -> NSRect? {
        guard blockIndex < blocks.count,
              let tlm = textLayoutManager,
              let range = blockTextRange(blocks[blockIndex].range, tlm) else { return nil }
        return unionOfSegments(in: range, tlm)
    }

    private func unionOfSegments(in range: NSTextRange, _ tlm: NSTextLayoutManager) -> NSRect? {
        let origin = textContainerOrigin
        var union: NSRect?
        tlm.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
            let r = frame.offsetBy(dx: origin.x, dy: origin.y)
            union = union.map { $0.union(r) } ?? r
            return true
        }
        return union
    }

    /// The width the popup takes: a whole row's, so moving between columns
    /// slides the arrow without resizing the field under the user's eye.
    func cellEditorWidth(blockIndex: Int) -> CGFloat {
        max(Self.cellEditorMinWidth, tableRect(blockIndex: blockIndex)?.width ?? 0)
    }

    /// How far along the card the arrow sits: the cell's text centre, measured
    /// from the card's left edge — which is the row's. This is the only thing
    /// that changes as the user moves along a row.
    func cellEditorArrowX(for cell: TableCellRef) -> CGFloat? {
        guard let table = tableRect(blockIndex: cell.blockIndex),
              let cellRect = tableCellRect(for: cell) else { return nil }
        return (tableCellTextCenterX(for: cell) ?? cellRect.midX) - table.minX
    }

    /// The centre of a cell's *glyphs* (view coordinates), which is not the
    /// centre of its cell rect: the padding that aligns a column is kern hung
    /// on the cell's own characters, so a short value in a wide column sits
    /// well off the rect's middle and the arrow has to follow the text.
    ///
    /// Measured off the laid-out segments of the trimmed content rather than by
    /// re-measuring the string, so it needs no alignment table and no bold
    /// fudge for the header row — whatever the renderer did, this reads back.
    ///
    /// The kern has to be undone at the edges: TextKit 2 splits the gap a kern
    /// opens evenly between the segments either side of it, so a trimmed range
    /// whose neighbour carries the column's padding measures half a gap too
    /// wide on that side. A kern on a line's last character is dropped from the
    /// segments entirely, so there is nothing to undo there.
    ///
    /// Returns nil — meaning "use the column's centre" — for an empty cell.
    private func tableCellTextCenterX(for cell: TableCellRef) -> CGFloat? {
        guard let tlm = textLayoutManager,
              let storage = textContentStorage?.textStorage else { return nil }
        let ns = rawSource as NSString
        var lo = cell.contentRange.location
        var hi = min(cell.contentRange.upperBound, min(ns.length, storage.length))
        while lo < hi, ns.character(at: lo) == 0x20 { lo += 1 }
        while hi > lo, ns.character(at: hi - 1) == 0x20 { hi -= 1 }
        guard hi > lo,
              let range = blockTextRange(NSRange(location: lo, length: hi - lo), tlm),
              var rect = unionOfSegments(in: range, tlm) else { return nil }

        let kernBefore = lo > 0
            ? (storage.attribute(.kern, at: lo - 1, effectiveRange: nil) as? CGFloat ?? 0) : 0
        let endsTheLine = hi >= ns.length || ns.character(at: hi) == 0x0A
        let kernAfter = endsTheLine
            ? 0 : (storage.attribute(.kern, at: hi - 1, effectiveRange: nil) as? CGFloat ?? 0)
        rect.origin.x += kernBefore / 2
        rect.size.width -= kernBefore / 2 + kernAfter / 2
        return rect.midX
    }

    /// Where the panel goes, in screen coordinates, and where its arrow points.
    ///
    /// The card is a row wide and hangs off the row being edited: the table's
    /// left edge and width, top edge on the bottom of that row. Only `arrowX`
    /// changes as the user moves along the row. Returns nil when the table
    /// isn't laid out.
    func cellEditorPlacement(for cell: TableCellRef, height: CGFloat)
        -> (frame: NSRect, arrowX: CGFloat)? {
        guard let window,
              let table = tableRect(blockIndex: cell.blockIndex),
              let cellRect = tableCellRect(for: cell) else { return nil }
        // The view is flipped, so the row's bottom edge is its maxY.
        // `styleTableSpan` gives every row `paragraphSpacing = cellVPad`, which
        // the segment rect carries — anchoring on the raw maxY leaves that pad
        // as a visible gap between the row and the arrow.
        let trailingPad = bodyFont.pointSize * 0.15
        // Frozen for the session. Typing reflows the table under the card —
        // a column widens, a neighbouring cell wraps — and re-reading the row
        // every keystroke would walk the card up and down under the pointer.
        // View coordinates, not screen, so scrolling still carries it along.
        let anchorY = cellEditorAnchorY ?? (cellRect.maxY - trailingPad)
        cellEditorAnchorY = anchorY
        let bottomLeftInView = NSPoint(x: table.minX, y: anchorY)
        let inWindow = convert(bottomLeftInView, to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        let width = max(Self.cellEditorMinWidth, table.width)
        let frame = NSRect(x: onScreen.x,
                           y: onScreen.y - Self.cellEditorGap - height,
                           width: width, height: height)
        let center = tableCellTextCenterX(for: cell) ?? cellRect.midX
        return (frame, center - table.minX)
    }

    // MARK: - Opening

    /// The cell a click would edit, or nil if the click isn't on an editable
    /// cell of a *rendered* table.
    ///
    /// A table showing its raw markdown is excluded: the caret is already in it,
    /// the user is already editing the source, and a second editor on top of
    /// that would be two editors for one piece of text.
    func tableCellForCellEditor(at event: NSEvent) -> TableCellRef? {
        guard let offset = wrappedCellCharIndex(at: event) ?? clickCharIndex(at: event),
              let cell = tableCell(atRawOffset: offset),
              activeBlockIndex != cell.blockIndex else { return nil }
        return cell
    }

    /// Opens the popup editor on `cell`, or slides an open one over to it.
    ///
    /// Only along a row does the card slide. Changing row closes it and opens a
    /// fresh one: the exit and the entrance then overlap, which reads as the
    /// card hopping from one row to the other rather than gliding through the
    /// table's middle.
    func openTableCellEditor(_ cell: TableCellRef) {
        if let current = editingTableCell, current.blockIndex == cell.blockIndex,
           current.row == cell.row, cellEditorPanel != nil, !isCellEditorDetached {
            moveTableCellEditor(toRow: cell.row, column: cell.column)
            return
        }
        closeTableCellEditor(commit: true)
        guard let window else { return }
        // That close committed whatever cell was open, which can have shifted
        // every range after it — this one included.
        guard let cell = tableCell(blockIndex: cell.blockIndex,
                                   row: cell.row, column: cell.column) else { return }

        editingTableCell = cell
        let controller = TableCellEditorController(
            text: (rawSource as NSString).substring(with: cell.contentRange),
            font: bodyFont,
            style: { [weak self] text, caret in
                self?.styleBlock(text, cursorPosition: caret)
            },
            onCommit: { [weak self] in self?.closeTableCellEditor(commit: true) },
            onCancel: { [weak self] in self?.closeTableCellEditor(commit: false) },
            onTear: { [weak self] event in self?.detachCellEditor(with: event) },
            onStep: { [weak self] delta in self?.stepTableCellEditor(by: delta) })
        controller.onHeightChange = { [weak self] in self?.liveApplyCellEdit() }

        let panel = CellEditorPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60))
        panel.controller = controller
        panel.contentView = controller.view
        cellEditorPanel = panel
        isCellEditorDetached = false
        cellEditorDidSnapshot = false
        cellEditorAnchorY = nil

        repositionCellEditor()
        // Drops the last few points into place while fading in. Deliberately
        // small and quick: the card is anchored to a cell the eye is already on,
        // so anything longer reads as lag rather than as motion.
        let destination = panel.frame
        var entry = destination
        entry.origin.y += Self.cellEditorTravel
        panel.setFrame(entry, display: false)
        panel.alphaValue = 0
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.cellEditorFade
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(destination, display: true)
            panel.animator().alphaValue = 1
        }
        controller.focus()
        observeForCellEditor()
    }

    /// Writes the popup's current text into the cell on every keystroke, so the
    /// table reflows — columns widen, rows wrap — under the card as the user
    /// types, rather than snapping when the card closes.
    ///
    /// The whole session is still one undo step: `applyFormattingEdit` pushes a
    /// snapshot per call, and every one after the first is dropped again, so
    /// ⌘Z returns to the text the cell had when the card opened.
    func liveApplyCellEdit() {
        guard let cell = editingTableCell, let controller = cellEditorController else { return }
        // Never mid-composition: the field holds provisional marked text then,
        // and that must not reach the document (ARCHITECTURE §8).
        guard !controller.isComposing else { return }
        editingTableCell = commitTableCellLive(cell, text: controller.liveText())
        repositionCellEditor(animateArrow: false)
    }

    /// One keystroke's worth of write-back, folded into this session's single
    /// undo step, returning the cell renamed by position — the write shifts
    /// every range after it, so the old `contentRange` is stale immediately.
    @discardableResult
    func commitTableCellLive(_ cell: TableCellRef, text: String) -> TableCellRef {
        let depth = undoStack.count
        commitTableCell(cell, text: text)
        guard undoStack.count > depth else { return cell }
        if cellEditorDidSnapshot {
            // Keep the *first* snapshot of the session and drop this one, so
            // undo lands on the text the cell had when the card opened rather
            // than on the previous keystroke.
            undoStack.removeLast()
        } else {
            cellEditorDidSnapshot = true
        }
        return tableCell(blockIndex: cell.blockIndex, row: cell.row, column: cell.column) ?? cell
    }

    /// Puts the panel back under its cell at its current height, and moves the
    /// arrow to the column being edited. The frame is recomputed from scratch,
    /// so a cell that changed width (typing can redistribute the columns)
    /// carries the panel with it.
    func repositionCellEditor(animateArrow: Bool = true) {
        guard let panel = cellEditorPanel, let controller = panel.controller,
              let cell = editingTableCell, !isCellEditorDetached else { return }
        guard let placement = cellEditorPlacement(for: cell,
                                                  height: controller.fittingHeight(width: nil))
        else {
            closeTableCellEditor(commit: true)
            return
        }
        // The arrow glides only when the card is already up; on first show it
        // must start where it belongs.
        controller.setArrowX(placement.arrowX, animated: animateArrow && panel.isVisible)
        // Height is measured against the width the panel is about to have, then
        // the frame is built from that height — otherwise a width change and a
        // wrap change chase each other by one frame.
        let height = controller.fittingHeight(width: placement.frame.width)
        var frame = placement.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    /// Commits the open cell and re-anchors on another cell of the same table.
    /// Only the arrow moves — the card is a row wide, so the field stays exactly
    /// where the user is already looking.
    func moveTableCellEditor(toRow row: Int, column: Int) {
        guard let current = editingTableCell,
              let controller = cellEditorController else { return }
        commitTableCell(current, text: controller.committedText())

        // After the commit the table has been reparsed and relaid out, so the
        // target has to be found again by position — its old range is stale.
        guard let target = tableCell(blockIndex: current.blockIndex, row: row, column: column)
        else {
            closeTableCellEditor(commit: false)
            return
        }
        editingTableCell = target
        cellEditorDidSnapshot = false
        cellEditorAnchorY = nil
        controller.load(text: (rawSource as NSString).substring(with: target.contentRange))
        repositionCellEditor()
        controller.focus()
    }

    /// The cell one step along the current row, for Tab / Shift-Tab.
    func stepTableCellEditor(by delta: Int) {
        guard let current = editingTableCell,
              tableCell(blockIndex: current.blockIndex,
                        row: current.row, column: current.column + delta) != nil else { return }
        moveTableCellEditor(toRow: current.row, column: current.column + delta)
    }

    var cellEditorController: TableCellEditorController? { cellEditorPanel?.controller }

    // MARK: - Tear-off

    /// Pulls the panel off the table into a free-floating window, the way a
    /// Calendar event's popover detaches when you drag it. Nothing is rebuilt —
    /// the same window stops being a child and stops tracking.
    func detachCellEditor(with event: NSEvent) {
        guard let panel = cellEditorPanel, !isCellEditorDetached else { return }
        isCellEditorDetached = true
        window?.removeChildWindow(panel)
        panel.level = .floating
        panel.controller?.setDetached(true)
        panel.makeKeyAndOrderFront(nil)
        // Continue the same gesture, so the window comes away under the pointer
        // instead of appearing and waiting for a second drag.
        panel.performDrag(with: event)
    }

    // MARK: - Closing and write-back

    /// Closes the popup, writing its text back when `commit`.
    ///
    /// Safe to call twice: `editingTableCell` is cleared first, which guards the
    /// re-entry that closing can itself provoke.
    func closeTableCellEditor(commit: Bool) {
        guard let cell = editingTableCell else { return }
        let controller = cellEditorController
        editingTableCell = nil
        stopObservingForCellEditor()

        let panel = cellEditorPanel
        cellEditorPanel = nil
        isCellEditorDetached = false
        cellEditorAnchorY = nil
        if let panel {
            panel.controller = nil
            // The entrance run backwards: rises the same few points and fades.
            var exit = panel.frame
            exit.origin.y += Self.cellEditorTravel
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.cellEditorFade
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(exit, display: true)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.parent?.removeChildWindow(panel)
                panel.close()
            })
        }

        guard commit, let controller else { return }
        commitTableCell(cell, text: controller.committedText())
    }

    /// A click anywhere that isn't a cell of the table being edited ends the
    /// edit. Nothing dismisses this panel for us.
    func dismissCellEditorIfClickIsOutside(_ event: NSEvent) {
        guard editingTableCell != nil, !isCellEditorDetached else { return }
        if let cell = tableCellForCellEditor(at: event),
           cell.blockIndex == editingTableCell?.blockIndex { return }
        closeTableCellEditor(commit: true)
    }

    private func observeForCellEditor() {
        stopObservingForCellEditor()
        guard let window else { return }
        let center = NotificationCenter.default
        cellEditorKeyObserver = center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isCellEditorDetached else { return }
                self.closeTableCellEditor(commit: true)
            }
        }
        // The panel is a child window, so it follows the window on its own; it
        // does not follow the *content* scrolling under it.
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            cellEditorScrollObserver = center.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.repositionCellEditor() }
            }
        }
    }

    private func stopObservingForCellEditor() {
        for token in [cellEditorKeyObserver, cellEditorScrollObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(token)
        }
        cellEditorKeyObserver = nil
        cellEditorScrollObserver = nil
    }

    /// Writes `text` back into `cell`, as one undoable step.
    func commitTableCell(_ cell: TableCellRef, text: String) {
        guard cell.blockIndex < blocks.count,
              blocks[cell.blockIndex].kind == .table,
              cell.contentRange.upperBound <= (rawSource as NSString).length else { return }
        let replacement = Self.sanitizedTableCellText(text)
        let existing = (rawSource as NSString).substring(with: cell.contentRange)
        guard replacement != existing else { return }

        // Keep the caret where it was. Anywhere inside the table would make it
        // the active block and render it raw, undoing the popup's whole point.
        // The live selection *is* the pre-edit one: opening the popup consumes
        // the click before `super.mouseDown`, so AppKit never moved the caret.
        let delta = (replacement as NSString).length - cell.contentRange.length
        var caret = selectedRange()
        if caret.location >= cell.contentRange.upperBound {
            caret.location += delta
        }
        applyFormattingEdit(rawRange: cell.contentRange, replacement: replacement, select: caret)
    }

    /// Makes `text` safe to drop between two pipes.
    ///
    /// A GFM cell cannot span lines, and an unescaped `|` would silently split
    /// the cell in two — so both are neutralised rather than allowed to corrupt
    /// the table's shape. `\|` is content the parser already understands (GFM
    /// Example 200, honoured by `cellRanges`/`splitTableRow`).
    static func sanitizedTableCellText(_ text: String) -> String {
        var out = ""
        var prevWasBackslash = false
        for ch in text {
            switch ch {
            // `isNewline`, not a list of literals: "\r\n" is a single Swift
            // Character, so matching "\n" and "\r" separately misses it and
            // lets a CRLF through into the row.
            case let ch where ch.isNewline:
                out.append(" ")
            case "|" where !prevWasBackslash:
                out.append("\\|")
            default:
                out.append(ch)
            }
            prevWasBackslash = (ch == "\\") && !prevWasBackslash
        }
        // Single spaces around the content keep the raw markdown readable, and
        // match how a table written by hand looks.
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? " " : " \(trimmed) "
    }
}

// MARK: - The window

/// Borderless so it reads as a card rather than a document window, which means
/// `canBecomeKey` has to be granted by hand — a borderless window is refused key
/// status otherwise, and this one has to take typing.
@MainActor
public final class CellEditorPanel: NSPanel {
    var controller: TableCellEditorController?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isMovableByWindowBackground = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
    }

    public override var canBecomeKey: Bool { true }
}

// MARK: - The bubble

/// Draws the card and its arrow. The arrow's x is the only thing that changes
/// as the user moves along a row, and it slides there rather than jumping.
@MainActor
final class CellEditorChrome: NSView {
    static let arrowHeight: CGFloat = 7
    static let arrowHalfWidth: CGFloat = 7
    static let cornerRadius: CGFloat = 7
    private static let arrowGlide: CFTimeInterval = 0.16

    private(set) var arrowX: CGFloat = 20
    var showsArrow = true { didSet { needsDisplay = true } }

    /// A drag starting on the card's own surface — the padding above the text,
    /// never the text itself, which has to keep its selection drag — tears the
    /// card off the table.
    var onDrag: ((NSEvent) -> Void)?
    private var dragOrigin: NSPoint?

    private var glideFrom: CGFloat = 0
    private var glideTo: CGFloat = 0
    private var glideProgress: CGFloat = 1
    private var glideLink: CADisplayLink?

    /// Moves the arrow. Animated, the card reads as one object sliding its
    /// pointer along the table rather than blinking between columns.
    func setArrowX(_ x: CGFloat, animated: Bool) {
        guard animated, abs(x - arrowX) > 0.5 else {
            glideLink?.invalidate()
            glideLink = nil
            glideProgress = 1
            arrowX = x
            needsDisplay = true
            return
        }
        glideFrom = arrowX
        glideTo = x
        glideProgress = 0
        glideLink?.invalidate()
        let link = displayLink(target: self, selector: #selector(stepGlide))
        link.add(to: .main, forMode: .common)
        glideLink = link
    }

    @objc private func stepGlide(_ link: CADisplayLink) {
        glideProgress = min(1, glideProgress + CGFloat(link.duration / Self.arrowGlide))
        // Ease out, so it settles rather than stopping dead.
        let t = 1 - pow(1 - glideProgress, 3)
        arrowX = glideFrom + (glideTo - glideFrom) * t
        needsDisplay = true
        if glideProgress >= 1 {
            link.invalidate()
            glideLink = nil
        }
    }

    override func mouseDown(with event: NSEvent) { dragOrigin = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragOrigin else { return }
        let moved = hypot(event.locationInWindow.x - start.x,
                          event.locationInWindow.y - start.y)
        // A few points of slop, so a twitch on mouse-down doesn't tear it off.
        guard moved > 4 else { return }
        dragOrigin = nil
        onDrag?(event)
    }

    override func mouseUp(with event: NSEvent) { dragOrigin = nil }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func draw(_ dirtyRect: NSRect) {
        // The window is transparent, so drawing composites over the last frame
        // unless the old pixels are actually removed — that is what left a
        // second arrow behind every time this one moved.
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)

        let inset: CGFloat = 0.5
        let r = Self.cornerRadius
        let top = bounds.maxY - (showsArrow ? Self.arrowHeight : 0) - inset
        let minX = bounds.minX + inset, maxX = bounds.maxX - inset
        let minY = bounds.minY + inset

        // One continuous outline, with the arrow spliced into the top edge —
        // not a triangle appended as its own subpath, which would stroke the
        // body's top edge straight across the arrow's base and give it a floor.
        let path = NSBezierPath()
        path.move(to: NSPoint(x: minX + r, y: top))
        if showsArrow {
            let x = min(max(arrowX, minX + r + Self.arrowHalfWidth),
                        maxX - r - Self.arrowHalfWidth)
            path.line(to: NSPoint(x: x - Self.arrowHalfWidth, y: top))
            path.line(to: NSPoint(x: x, y: bounds.maxY - inset))
            path.line(to: NSPoint(x: x + Self.arrowHalfWidth, y: top))
        }
        path.line(to: NSPoint(x: maxX - r, y: top))
        path.appendArc(from: NSPoint(x: maxX, y: top), to: NSPoint(x: maxX, y: top - r), radius: r)
        path.line(to: NSPoint(x: maxX, y: minY + r))
        path.appendArc(from: NSPoint(x: maxX, y: minY), to: NSPoint(x: maxX - r, y: minY), radius: r)
        path.line(to: NSPoint(x: minX + r, y: minY))
        path.appendArc(from: NSPoint(x: minX, y: minY), to: NSPoint(x: minX, y: minY + r), radius: r)
        path.line(to: NSPoint(x: minX, y: top - r))
        path.appendArc(from: NSPoint(x: minX, y: top), to: NSPoint(x: minX + r, y: top), radius: r)
        path.close()

        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        // A borderless window's shadow is cached from the shape last drawn, and
        // moving the arrow changes that shape. Without this the old arrow's
        // silhouette stays on screen as a ghost outline after the card has
        // moved on — the content is right, the shadow is stale. Invisible to
        // `screencapture -l`, which grabs content and not shadow.
        window?.invalidateShadow()
    }
}

// MARK: - The editor itself

/// A one-cell markdown editor: a plain `NSTextView`, deliberately not an
/// `EditorTextView`. It wants none of the block pipeline — there is one block,
/// it is a few dozen characters, and it is not the document.
@MainActor
public final class TableCellEditorController: NSViewController {

    private let field = CellTextView()
    private let scroll = NSScrollView()
    private let closeButton = NSButton()
    private let chrome = CellEditorChrome()
    private var initialText: String
    private let font: NSFont

    /// Air above the text. Doubles as the only place a drag can start a
    /// tear-off — a drag on the text itself has to stay a selection.
    private static let topPadding: CGFloat = 8
    private static let bottomPadding: CGFloat = 8

    var onHeightChange: (() -> Void)?

    init(text: String, font: NSFont,
         style: @escaping (String, Int?) -> NSAttributedString?,
         onCommit: @escaping () -> Void, onCancel: @escaping () -> Void,
         onTear: @escaping (NSEvent) -> Void, onStep: @escaping (Int) -> Void) {
        self.initialText = text
        self.font = font
        super.init(nibName: nil, bundle: nil)
        field.onCancel = onCancel
        field.onCommit = onCommit
        field.onStep = onStep
        field.style = style
        field.onTextChanged = { [weak self] in self?.onHeightChange?() }
        chrome.onDrag = onTear
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override func loadView() {
        field.string = initialText.trimmingCharacters(in: .whitespaces)
        field.font = font
        field.isRichText = false
        field.isAutomaticQuoteSubstitutionEnabled = false
        field.isAutomaticDashSubstitutionEnabled = false
        field.isAutomaticTextReplacementEnabled = false
        // Same reason the main editor disables it: completion injects
        // provisional marked text, and marked text is the hazard here.
        field.isAutomaticTextCompletionEnabled = false
        field.drawsBackground = false
        field.textContainerInset = NSSize(width: 8, height: 0)
        field.isVerticallyResizable = true
        field.isHorizontallyResizable = false
        // A text view added to a scroll view keeps whatever frame it has, and a
        // freshly constructed one has none — so without these its container is
        // zero-sized and the card comes up blank.
        field.minSize = .zero
        field.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                               height: CGFloat.greatestFiniteMagnitude)
        field.autoresizingMask = [.width]
        field.textContainer?.widthTracksTextView = true
        field.textContainer?.lineFragmentPadding = 0

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = field

        closeButton.isHidden = true          // only the torn-off window shows it
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: "Close")
        closeButton.target = field
        closeButton.action = #selector(CellTextView.commitFromButton)

        chrome.addSubview(scroll)
        chrome.addSubview(closeButton)
        view = chrome
        field.restyle()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        layOutContents()
    }

    private func layOutContents() {
        let arrow = chrome.showsArrow ? CellEditorChrome.arrowHeight : 0
        let h = chrome.bounds.height
        let top = h - arrow - Self.topPadding
        scroll.frame = NSRect(x: 0, y: Self.bottomPadding,
                              width: chrome.bounds.width,
                              height: max(0, top - Self.bottomPadding))
        let content = scroll.contentSize
        field.frame = NSRect(origin: .zero,
                             size: NSSize(width: content.width,
                                          height: max(content.height, field.frame.height)))
        field.textContainer?.size = NSSize(
            width: max(10, content.width - 2 * field.textContainerInset.width),
            height: CGFloat.greatestFiniteMagnitude)
        closeButton.frame = NSRect(x: 6, y: h - arrow - 15, width: 13, height: 13)
    }

    /// Height the card needs for its text at `width` (nil = the current width).
    func fittingHeight(width: CGFloat?) -> CGFloat {
        let w = width ?? max(chrome.bounds.width, EditorTextView.cellEditorMinWidth)
        let inner = max(10, w - 2 * field.textContainerInset.width)
        guard let container = field.textContainer, let tlm = field.textLayoutManager else {
            return 44
        }
        container.size = NSSize(width: inner, height: .greatestFiniteMagnitude)
        tlm.ensureLayout(for: tlm.documentRange)
        var textHeight: CGFloat = 0
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) {
            textHeight = max(textHeight, $0.layoutFragmentFrame.maxY)
            return true
        }
        let arrow = chrome.showsArrow ? CellEditorChrome.arrowHeight : 0
        let body = min(max(textHeight, font.pointSize + 6), 260)
        return arrow + Self.topPadding + body + Self.bottomPadding
    }

    /// Swaps in another cell's text without rebuilding the card.
    func load(text: String) {
        initialText = text
        field.string = text.trimmingCharacters(in: .whitespaces)
        field.restyle()
    }

    func setArrowX(_ x: CGFloat, animated: Bool) { chrome.setArrowX(x, animated: animated) }

    /// The text as it stands right now, for the live write-back on each
    /// keystroke. Only meaningful while `isComposing` is false.
    func liveText() -> String { field.string }

    var isComposing: Bool { field.hasMarkedText() }

    func setDetached(_ detached: Bool) {
        closeButton.isHidden = !detached
        chrome.showsArrow = !detached
        layOutContents()
    }

    func focus() {
        view.window?.makeFirstResponder(field)
        field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
    }

    #if DEBUG
    func reproInsert(_ text: String) {
        field.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    #endif

    /// The edited text, with any in-flight IME composition finalised first —
    /// reading `string` mid-composition would capture a half-formed syllable.
    func committedText() -> String {
        if field.hasMarkedText() {
            field.inputContext?.discardMarkedText()
            field.unmarkText()
        }
        return field.string
    }
}

// MARK: - The field

/// Esc cancels, ⏎ commits, Tab steps along the row — a table cell cannot hold a
/// newline or a tab, so none of those keys has anything else to mean here.
///
/// The text renders with the document's own inline styling, live. That is a
/// single `styleBlock` call because the card holds exactly one block of a few
/// dozen characters: none of the incremental machinery the main editor needs
/// (block diffing, dirty sets, lazy styling, viewport layout) applies at this
/// size, so a full restyle per keystroke is the cheap option as well as the
/// simple one.
@MainActor
private final class CellTextView: NSTextView {
    var onCancel: (() -> Void)?
    var onCommit: (() -> Void)?
    var onStep: ((Int) -> Void)?
    var onTextChanged: (() -> Void)?
    var style: ((String, Int?) -> NSAttributedString?)?

    private var isRestyling = false

    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func insertNewline(_ sender: Any?) { onCommit?() }
    override func insertTab(_ sender: Any?) { onStep?(1) }
    override func insertBacktab(_ sender: Any?) { onStep?(-1) }

    @objc func commitFromButton() { onCommit?() }

    override func didChangeText() {
        super.didChangeText()
        restyle()
        onTextChanged?()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity,
                                    stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // Which delimiters show depends on where the caret is, exactly as it
        // does in the document.
        guard !stillSelecting, !isRestyling else { return }
        restyle()
    }

    /// Re-applies the document's inline styling to the whole field.
    func restyle() {
        // Never while an IME is composing: storage holds provisional marked text
        // then, and restyling through it is what strands the composition
        // (ARCHITECTURE §8).
        guard !isRestyling, !hasMarkedText(), let style,
              let storage = textStorage else { return }
        let text = storage.string
        guard let styled = style(text, selectedRange().location),
              styled.length == (text as NSString).length else { return }
        isRestyling = true
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        styled.enumerateAttributes(in: full) { attrs, range, _ in
            // Paragraph style is the card's own business — the document's block
            // spacing and indents would push the single line around.
            var attrs = attrs
            attrs.removeValue(forKey: .paragraphStyle)
            storage.setAttributes(attrs, range: range)
        }
        storage.endEditing()
        isRestyling = false
    }
}

#if DEBUG
// MARK: - Repro hooks
//
// The card only ever opens from a real mouse click, and a background app
// cannot take focus to receive one — so without these a script can never get
// the card on screen to look at. See ReproScript's `cellpopup` / `cellstep`.

extension EditorTextView {
    public func reproTableCell(atRawOffset offset: Int) -> TableCellRef? {
        tableCell(atRawOffset: offset)
    }

    public func reproOpenTableCellEditor(_ cell: TableCellRef) {
        openTableCellEditor(cell)
    }

    public func reproStepTableCellEditor(by delta: Int) {
        stepTableCellEditor(by: delta)
    }

    /// Types into the open card. The panel is key when it is up, so a scripted
    /// keystroke aimed at the document window would go to the wrong view.
    public func reproTypeInCellEditor(_ text: String) {
        cellEditorController?.reproInsert(text)
    }
}
#endif
