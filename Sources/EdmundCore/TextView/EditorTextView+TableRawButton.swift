import AppKit

// MARK: - Table raw-editing button
//
// A `</>` affordance in the line numbers' slot, level with each table's header
// row. Clicking it puts the caret in the table, and the caret being in the
// table is what renders it as raw monospace markdown — the existing
// active-block behaviour. Clicking outside the table moves the caret out and
// renders it again, so "click outside to leave raw editing" needs no code of
// its own.
//
// It is the way back to the markdown now that a plain click on a cell opens the
// popup editor instead (EditorTextView+TableCellEditor).
//
// The margin stays empty until the pointer is over the table or the caret is
// inside it. While the button shows and the numbers are on, it stands in for
// that row's number rather than crowding it — one slot, one occupant.
//
// It draws on the background pass beside the text, exactly like the numbers,
// and never inside a layout fragment. Two things follow: it sits outside the
// reading column (beyond the max content width), and the image-wedge constraint
// on fragment overlays (ARCHITECTURE §4 — an image overlay wedges a wrapping
// fragment to one line) does not apply, so this can be a real SF Symbol rather
// than a stroked path.

extension EditorTextView {

    /// Side of the button's square draw/hit box.
    static let tableRawButtonSize: CGFloat = 13

    // MARK: - Geometry

    /// The button box (view coordinates) and its block index, for every table
    /// whose header row is in the laid-out viewport — whether or not it is
    /// currently revealed.
    ///
    /// Position comes from `enumerateVisibleLineNumbers`, so the button lands in
    /// exactly the slot the line number for that row would occupy: the same
    /// right edge, and the same cap-band centring (the line box carries the
    /// table's leading paragraph spacing, so centring in it rides high). That
    /// enumeration is not gated on `showLineNumbers` — only the numbers' own
    /// draw is — so the slot is there to use with the numbers off.
    ///
    /// It also walks the viewport the text view has *already* laid out, for the
    /// reason it documents: forcing layout from inside a draw re-enters the
    /// viewport layout controller and blanks the view.
    func visibleTableRawButtons() -> [(rect: NSRect, blockIndex: Int)] {
        // ponytail: rebuilt per draw rather than cached against `blocks` — one
        // pass over the block list, and `line(forOffset:)` is a binary search
        // over the cached line starts. Cache it if a huge document ever shows
        // up in a scroll profile.
        var headerLines: [Int: Int] = [:]
        for (i, block) in blocks.enumerated() where block.kind == .table {
            headerLines[line(forOffset: block.range.location)] = i
        }
        guard !headerLines.isEmpty else { return [] }

        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        let rightEdge = origin.x + padding - Self.lineNumberPadding
        let size = Self.tableRawButtonSize
        var result: [(rect: NSRect, blockIndex: Int)] = []
        enumerateVisibleLineNumbers { line, capCenterY in
            guard let blockIndex = headerLines[line] else { return }
            result.append((NSRect(x: rightEdge - size,
                                  y: origin.y + capCenterY - size / 2,
                                  width: size, height: size), blockIndex))
        }
        return result
    }

    /// Whether a table's button is currently showing.
    ///
    /// Hover only. A caret inside the table used to reveal it too, but the row
    /// handle now claims that same margin slot — so the caret being in a table
    /// reveals the handles instead, and their menus carry "Edit as Markdown".
    /// Two affordances, never both at once.
    func tableRawButtonIsRevealed(blockIndex: Int) -> Bool {
        hoveredTableBlock == blockIndex && activeBlockIndexForRawTable() != blockIndex
    }

    /// The buttons actually on screen — the only ones that draw, and the only
    /// ones that can be clicked.
    func revealedTableRawButtons() -> [(rect: NSRect, blockIndex: Int)] {
        visibleTableRawButtons().filter { tableRawButtonIsRevealed(blockIndex: $0.blockIndex) }
    }

    /// Line numbers something else in the margin is standing in for, so the
    /// numbers' own draw can leave those rows to it: a revealed `</>` button,
    /// or the active row's handle. Both sit within `lineNumberPadding` of where
    /// a number ends, so without this they overlap it.
    func linesCoveredByTableRawButtons() -> Set<Int> {
        var covered = Set(revealedTableRawButtons()
            .map { line(forOffset: blocks[$0.blockIndex].range.location) })
        if let cell = activeTableCell, cell.blockIndex < blocks.count {
            covered.insert(line(forOffset: cell.contentRange.location))
        }
        return covered
    }

    // MARK: - Drawing

    /// Ink for the `</>` glyph. A tier up from `syntaxDimColor`, which resolves
    /// to `tertiaryLabelColor` — black at 26% alpha. That is the right weight
    /// for a delimiter sitting inside a line of text, where the text around it
    /// gives the eye something to read it against; alone out in the margin the
    /// glyph all but disappeared. Dark mode already substitutes its own gray
    /// for the dim tier for the same legibility reason, so it keeps that one.
    private var tableRawButtonColor: NSColor {
        isDarkAppearance ? syntaxDimColor : .secondaryLabelColor
    }

    /// Draws the `</>` buttons. Called from `drawBackground(in:)` — they occupy
    /// margin the text never uses, so nothing has to move to make room.
    func drawTableRawButtons(in rect: NSRect) {
        let boxes = revealedTableRawButtons().filter { $0.rect.intersects(rect) }
        guard !boxes.isEmpty else { return }
        // ponytail: the symbol image is rebuilt per draw. It is one small
        // template image per visible table; give it a cache only if it shows up
        // in a scroll profile.
        guard let symbol = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right",
                                   accessibilityDescription: "Edit table as Markdown"),
              let configured = symbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: Self.tableRawButtonSize, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [tableRawButtonColor])))
        else { return }

        for (box, blockIndex) in boxes {
            if tableRawButtonHovered && hoveredTableBlock == blockIndex {
                // Space, not a border: the editor's chrome idiom. A soft fill
                // is enough to read as a target under the pointer.
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: box.insetBy(dx: -3, dy: -3),
                             xRadius: 4, yRadius: 4).fill()
            }
            // The symbol is wider than it is tall; fit it in the box by its own
            // aspect so the glyph isn't squashed into the square hit target.
            let drawn = configured.size
            let scale = min(box.width / drawn.width, box.height / drawn.height)
            let fitted = NSSize(width: drawn.width * scale, height: drawn.height * scale)
            configured.draw(in: NSRect(x: box.midX - fitted.width / 2,
                                       y: box.midY - fitted.height / 2,
                                       width: fitted.width, height: fitted.height))
        }
    }

    // MARK: - Pointer tracking

    /// Hit box for a button — generous, because the drawn glyph is small chrome
    /// and the margin around it is empty, so the slack is free.
    private func tableRawButtonHitBox(_ rect: NSRect) -> NSRect {
        rect.insetBy(dx: -4, dy: -4)
    }

    /// Recomputes what the pointer is over and redraws if it changed.
    ///
    /// A table counts as hovered anywhere from its button's slot across to the
    /// right edge of the text column, so the pointer can travel from the table
    /// out to the button without the button vanishing on the way.
    func updateTableHover(at point: NSPoint) {
        var block: Int?
        var onButton = false
        for (rect, blockIndex) in visibleTableRawButtons() {
            guard let range = tableRowsRect(blockIndex: blockIndex) else { continue }
            let band = NSRect(x: rect.minX, y: range.minY,
                              width: max(0, bounds.maxX - rect.minX), height: range.height)
            // The button sits above the header row's own band when the row is
            // short, so test it separately rather than relying on the band.
            if tableRawButtonHitBox(rect).contains(point) {
                block = blockIndex
                onButton = true
                break
            }
            if band.contains(point) { block = blockIndex }
        }
        guard block != hoveredTableBlock || onButton != tableRawButtonHovered else { return }
        hoveredTableBlock = block
        tableRawButtonHovered = onButton
        needsDisplay = true
    }

    /// The on-screen band a table's rows occupy (view coordinates).
    private func tableRowsRect(blockIndex: Int) -> NSRect? {
        guard blockIndex < blocks.count,
              let tlm = textLayoutManager,
              let range = blockTextRange(blocks[blockIndex].range, tlm) else { return nil }
        let origin = textContainerOrigin
        var union: NSRect?
        tlm.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
            let r = frame.offsetBy(dx: origin.x, dy: origin.y)
            union = union.map { $0.union(r) } ?? r
            return true
        }
        return union
    }

    /// `.mouseMoved` rather than plain enter/exit: the button is revealed by
    /// *where* in the view the pointer is, not merely by it being in the view.
    /// `.inVisibleRect` keeps the area in step with scrolling on its own.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = tableHoverTrackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tableHoverTrackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        updateTableHover(at: point)
        updateTableHandleHover(at: point)
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard hoveredTableBlock != nil || tableRawButtonHovered
                || hoveredTableHandle != nil else { return }
        hoveredTableBlock = nil
        tableRawButtonHovered = false
        hoveredTableHandle = nil
        needsDisplay = true
    }

    /// The table whose `</>` button is under a mouse event, if any. Only a
    /// revealed button can be hit — an invisible one is not a target.
    func tableRawButtonHit(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return revealedTableRawButtons()
            .first { tableRawButtonHitBox($0.rect).contains(point) }?.blockIndex
    }

    // MARK: - Activation

    /// Toggles a table between its rendered form and its raw markdown, and
    /// puts the caret in it.
    ///
    /// The caret alone no longer renders a table raw — it edits the cell it
    /// lands in, in place — so unlike every other block this needs an explicit
    /// switch, which is what the button is for.
    func activateRawTableEditing(blockIndex: Int) {
        guard blockIndex < blocks.count else { return }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        let alreadyRaw = rawTableEditing
            && activeBlockIndexForRawTable() == blockIndex
        rawTableEditing = !alreadyRaw
        // Suppressed for the same reason `mouseDown` suppresses it: re-centring
        // the viewport because the user clicked something feels glitchy.
        suppressTypewriterCentering = true
        setSelectedRange(NSRange(location: blocks[blockIndex].range.location, length: 0))
        suppressTypewriterCentering = false
        restyleBlock(blockIndex, cursorInBlock: 0)
    }

    /// The table the caret is in, if any — the one `rawTableEditing` applies to.
    func activeBlockIndexForRawTable() -> Int? {
        guard let i = blockIndexForRawOffset(selectedRange().location),
              i < blocks.count, blocks[i].kind == .table else { return nil }
        return i
    }
}
