import AppKit

// MARK: - Caret, selection and vertical movement inside a wrapped table cell
//
// A cell too wide for its column hides its real characters and is redrawn from
// a detached scratch layout (`.tableCellWraps`). Every hidden character sits at
// the same x, one hundredth of a point apart, so AppKit puts the caret and the
// selection highlight at the column's left edge while the text the user is
// looking at is somewhere else entirely.
//
// Only the geometry is wrong. The characters under the drawn text are the
// document's own (storage == rawSource), so typing, deleting, undo, copy and
// the horizontal arrows already act on exactly the right text — they never
// consult a rect. So only the geometry is replaced here: the caret is drawn
// where the scratch layout puts it, the selection likewise, and Up/Down walk
// the cell's visual lines instead of stepping straight out of the row.
//
// The alternative was to stop wrapping the row being edited, which keeps the
// caret honest but lets that row run past the container and lose its column
// border — the table visibly breaks the moment you click into it.
//
// Both are drawn from `drawBackground(in:)`, behind the glyphs. That is not a
// preference: `drawInsertionPoint(in:color:turnedOn:)` is never called on
// macOS 15, where a TextKit 2 NSTextView draws its text, its caret and its
// selection into private `_NSTextContentView` / `_NSTextSelectionView` subviews
// layered above the view's own drawing. So AppKit's caret is switched off with a
// clear `insertionPointColor` rather than overridden, the blink it would have
// provided is run here, and — because a selection change never dirties the
// background pass — so is the invalidation.

extension EditorTextView {

    /// Half the blink cycle. AppKit reads `NSTextInsertionPointBlinkPeriodOn`
    /// and `…Off` for its own caret, so ours honours them too — someone who has
    /// turned blinking off gets a steady caret inside a table as well.
    private var caretBlinkInterval: TimeInterval {
        let key = wrappedCaretOn ? "NSTextInsertionPointBlinkPeriodOn"
                                 : "NSTextInsertionPointBlinkPeriodOff"
        let period = UserDefaults.standard.double(forKey: key) / 1000
        return period > 0 ? period : 0.5
    }

    /// View-coordinate rects covering `range` where it falls inside a wrapped
    /// cell's drawn text, one per visual line. Empty for every range that
    /// doesn't — which is all of them outside a table with an overflowing cell.
    public func wrappedCellRects(for range: NSRange) -> [NSRect] {
        guard let tlm = textLayoutManager,
              let storage = textStorage, storage.length > 0,
              range.location >= 0, range.upperBound <= storage.length,
              // Model, not layout: only a table row can wrap a cell, and this
              // runs on every selection change and every background draw, so
              // the layout work below must never touch a document without one.
              let blockIndex = blockIndexForRawOffset(range.location),
              blockIndex < blocks.count, blocks[blockIndex].kind == .table,
              let location = tlm.location(tlm.documentRange.location,
                                          offsetBy: range.location)
        else { return [] }
        // Lay the table out before reading the row's frame. A click's own
        // selection change restyles the whole table block (`applyBlockStyle`),
        // which invalidates every row's fragment; read before the next layout
        // pass, the caret's rects came out ~120pt too high and 10pt left, and
        // the band remembered for the *next* invalidation pointed at nothing —
        // so the caret left a solid copy of itself on its previous visual line.
        // Seen only before the first blink tick, which re-reads the band after
        // layout had caught up. Ensured from the document start, not from the
        // caret's paragraph or block: the restyle also resets the newline
        // before the block, so the paragraph above is invalid too, and TextKit
        // 2 stacks a partially ensured range straight after the last *valid*
        // fragment — 66pt off from the row alone, 5pt off from the block. A
        // no-op when everything is laid out (~15µs), ~1ms when it is not.
        if let through = NSTextRange(location: tlm.documentRange.location, end: location) {
            tlm.ensureLayout(for: through)
        }
        guard let fragment = tlm.textLayoutFragment(for: location)
                  as? DecoratedTextLayoutFragment,
              let paragraphStart = fragment.textElement?.elementRange?.location
        else { return [] }

        let base = tlm.offset(from: tlm.documentRange.location, to: paragraphStart)
        // A caret exactly on a paragraph boundary can resolve to the fragment
        // before it, which would put the range at a negative offset.
        guard range.location >= base else { return [] }
        let local = NSRange(location: range.location - base, length: range.length)
        let frame = fragment.layoutFragmentFrame
        let origin = textContainerOrigin
        return fragment.cellWrapRects(forParagraphRange: local).map {
            $0.offsetBy(dx: frame.minX + origin.x, dy: frame.minY + origin.y)
        }
    }

    /// Where the caret really is when it sits in a wrapped cell, or nil when it
    /// doesn't and AppKit's own caret is in the right place already.
    public func wrappedCellCaretRect() -> NSRect? {
        let selection = selectedRange()
        guard selection.length == 0,
              var rect = wrappedCellRects(for: selection).first else { return nil }
        rect.size.width = 1
        return rect
    }

    // MARK: - AppKit's caret

    /// AppKit's caret view (macOS 14+): a direct subview of the text view,
    /// created the first time the window is key. Nil until then — which is
    /// also why an inactive window never shows the flash this hides.
    private var appKitCaretView: NSTextInsertionIndicator? {
        subviews.lazy.compactMap { $0 as? NSTextInsertionIndicator }.first
    }

    /// Takes AppKit's caret off screen, or gives it back. A clear
    /// `insertionPointColor` and turning the insertion point off are not enough
    /// on their own: the indicator hides with a *fade*, and it fades after it
    /// has already been moved to the new selection — the cell's hidden
    /// characters, at the cell's start. A caret that was live in a non-wrapped
    /// cell (or outside the table) therefore ghosted at the cell's start for a
    /// few frames on every click into a wrapped cell: the flash. `isHidden` is
    /// not animated, so the fade, and the "moved" effect that comes with it,
    /// never paint. Verified frame by frame with a real HID click.
    func setAppKitCaretHidden(_ hidden: Bool) {
        guard let caret = appKitCaretView, caret.isHidden != hidden else { return }
        caret.isHidden = hidden
    }

    // MARK: - Drawing

    /// Paints the caret and the selection highlight where a wrapped cell's text
    /// actually is. Called from `drawBackground(in:)`, so both land behind the
    /// glyphs — which the highlight requires (drawn over them it would hide the
    /// very text it marks as selected) and the caret doesn't mind, being a
    /// hairline that falls between glyphs.
    func drawWrappedCellChrome(in rect: NSRect) {
        let selection = selectedRange()
        if selection.length > 0 {
            // A block of *cells* is marked by its box alone, like Notes: the
            // text highlight AppKit would draw is suppressed for it
            // (`setTableCellHighlight`), and this one must not stand in.
            guard tableCellSelection == nil else { return }
            // The standard selection colour, NOT `selectedTextAttributes` — that
            // is deliberately cleared while a wrapped/cell selection is up (to
            // suppress AppKit's own stray highlight over the hidden characters),
            // and reading it here would paint this highlight clear too.
            NSColor.selectedTextBackgroundColor.setFill()
            for highlight in wrappedCellRects(for: selection) where highlight.intersects(rect) {
                highlight.fill()
            }
            return
        }
        // Recomputed rather than cached: a resize or a restyle can move the
        // caret without the selection changing, and the cached band is only
        // ever used to work out what to invalidate.
        let caretRect = wrappedCellCaretRect()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debug.caretTrace"), let caretRect {
            var rectsPtr: UnsafePointer<NSRect>? = nil
            var count = 0
            getRectsBeingDrawn(&rectsPtr, count: &count)
            let dirty = (0..<count).map { "\(rectsPtr![$0])" }.joined(separator: " ")
            Log.info("carettrace draw t=\(Int(ProcessInfo.processInfo.systemUptime * 1000))"
                     + " rect=\(rect) caret=\(caretRect) on=\(wrappedCaretOn)"
                     + " hit=\(caretRect.intersects(rect)) dirty=[\(dirty)]",
                     category: .app)
        }
        #endif
        guard wrappedCaretOn, window?.firstResponder === self,
              let caret = caretRect, caret.intersects(rect) else { return }
        accentColor.setFill()
        caret.fill()
    }

    // MARK: - Keeping it on screen

    /// Keeps the hand-drawn chrome in step with the selection. Three jobs, all
    /// of them things AppKit would otherwise do and here cannot:
    ///
    ///   * repaint. Selection changes are drawn into `_NSTextSelectionView`,
    ///     which never dirties the view's own background pass — so the band the
    ///     chrome lives in has to be invalidated by hand, the old one as well as
    ///     the new, or a moved caret leaves a copy of itself behind.
    ///   * hide AppKit's caret, which would sit on the cell's hidden characters
    ///     at the column's left edge. Its selection highlight needs no hiding:
    ///     over ~zero-width characters it paints a sliver too thin to see.
    ///   * blink, which becomes this timer's job once AppKit's caret is off.
    func updateWrappedCaret() {
        let selection = selectedRange()
        let rects = wrappedCellRects(for: selection)
        let band = rects.isEmpty ? nil : chromeBand(rects)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debug.caretTrace") {
            Log.info("carettrace update t=\(Int(ProcessInfo.processInfo.systemUptime * 1000))"
                     + " sel=\(selection) rects=\(rects) stale=\(wrappedCaretRect.map { "\($0)" } ?? "nil")"
                     + " band=\(band.map { "\($0)" } ?? "nil")", category: .app)
        }
        #endif
        // One rect covering the old band and the new: cheaper than two
        // invalidations of overlapping strips, and it is what a ghost caret
        // needs — the old band is only ever right if it was read after layout
        // (see `wrappedCellRects`).
        switch (wrappedCaretRect, band) {
        case let (stale?, band?): setNeedsDisplay(stale.union(band))
        case let (stale?, nil): setNeedsDisplay(stale)
        case let (nil, band?): setNeedsDisplay(band)
        case (nil, nil): break
        }
        wrappedCaretRect = band

        guard !rects.isEmpty else {
            // Unconditional (a no-op when already shown): a wrapped *selection*
            // has no blink timer, yet AppKit's caret was hidden for it too.
            setAppKitCaretHidden(false)
            guard wrappedCaretTimer != nil else { return }
            wrappedCaretTimer?.invalidate()
            wrappedCaretTimer = nil
            insertionPointColor = accentColor
            return
        }
        insertionPointColor = .clear
        // Neither the clear colour nor turning the insertion point off stops the
        // indicator's *fade-out* at the new position; hiding the view does.
        // Here at the one place every caret-into-a-wrapped-cell update passes
        // through, so the click and the async selection-change path are both
        // covered. See `setAppKitCaretHidden`.
        updateInsertionPointStateAndRestartTimer(false)
        setAppKitCaretHidden(true)
        guard selection.length == 0 else {
            // A selection has no caret to blink.
            wrappedCaretTimer?.invalidate()
            wrappedCaretTimer = nil
            return
        }
        // A caret that just moved is a solid caret: restarting the cycle is
        // what stops it vanishing under the user's own typing.
        wrappedCaretOn = true
        scheduleCaretBlink()
    }

    /// The full-width strip the chrome sits in. Wider than the chrome itself on
    /// purpose: the rects are recomputed at draw time, so a stale band still has
    /// to cover wherever the fresh one turns out to be on those rows.
    private func chromeBand(_ rects: [NSRect]) -> NSRect {
        let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        return NSRect(x: 0, y: union.minY - 2,
                      width: bounds.width, height: union.height + 4)
    }

    private func scheduleCaretBlink() {
        wrappedCaretTimer?.invalidate()
        wrappedCaretTimer = Timer.scheduledTimer(
            withTimeInterval: caretBlinkInterval, repeats: false
        ) { [weak self] _ in
            // Scheduled on the main run loop, which is where all of this lives.
            // One shot, rescheduled by each tick, so a dead editor's last timer
            // simply fires into nothing rather than needing to be cancelled.
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let caret = self.wrappedCellCaretRect() else {
                    self.updateWrappedCaret()   // the caret left; hand AppKit's back
                    return
                }
                self.wrappedCaretOn.toggle()
                self.wrappedCaretRect = self.chromeBand([caret])
                self.setNeedsDisplay(self.chromeBand([caret]))
                self.scheduleCaretBlink()
            }
        }
    }

    // MARK: - Click and drag inside a wrapped cell

    /// Takes a single-click gesture whole when it lands on a wrapped cell's
    /// drawn text, so a drag there selects the visible text. AppKit's own
    /// tracking can't: the cell's real characters are hidden at one x, so it
    /// sweeps a meaningless range and — reading `mouseLocationOutsideOfEventStream`
    /// after the fact — never sees the drag at all. This runs its own tracking
    /// loop instead, mapping each drag event's *own* location through the scratch
    /// layout to the character under it, and selecting anchor…current.
    ///
    /// A click with no drag just lands the caret at the character clicked — the
    /// same place the old path put it, but without `super.mouseDown` ever placing
    /// AppKit's caret on the hidden characters first, so the caret no longer
    /// flashes to the cell's start. Returns false (letting `super` handle it) for
    /// a click that isn't a single click on wrapped text.
    func handleWrappedCellDrag(with event: NSEvent) -> Bool {
        guard !rawTableEditing, event.clickCount == 1,
              let window, let anchor = wrappedCellCharIndex(at: event),
              let anchorCell = tableCell(atRawOffset: anchor) else { return false }
        // Hide AppKit's caret *before* placing the selection. When the previous
        // click left it live in a non-wrapped cell or outside the table,
        // `setSelectedRange` moves it onto the wrapped cell's hidden characters
        // (the cell's start) and its hide there fades — the flash. Hidden
        // first, neither the move nor the fade ever paints; `updateWrappedCaret`
        // keeps it hidden afterwards. See `setAppKitCaretHidden`.
        insertionPointColor = .clear
        updateInsertionPointStateAndRestartTimer(false)
        setAppKitCaretHidden(true)
        if window.firstResponder !== self { window.makeFirstResponder(self) }
        suppressTypewriterCentering = true
        defer { suppressTypewriterCentering = false }
        setSelectedRange(NSRange(location: anchor, length: 0))
        updateWrappedCaret()
        var crossedCells = false
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }
            let point = convert(e.locationInWindow, from: nil)
            // Out of the anchor's cell: the gesture becomes a block of cells,
            // from the anchor's cell to the one under the pointer (clamped to
            // the table), exactly as a drag out of a non-wrapped cell does.
            if let now = tableCellPosition(at: point, blockIndex: anchorCell.blockIndex,
                                           ensuringLayout: true),
               now.row != anchorCell.row || now.column != anchorCell.column {
                crossedCells = true
                selectTableCells(blockIndex: anchorCell.blockIndex,
                                 from: (anchorCell.row, anchorCell.column), to: now)
                updateWrappedCaret()
                continue
            }
            if crossedCells {
                // Back inside after having left: the cell whole, not the sliver
                // under the pointer — the gesture keeps reading as picking cells.
                setSelectedRange(anchorCell.contentRange)
                updateWrappedCaret()
                continue
            }
            // Inside the anchor's cell but off its drawn text (the pad): keep
            // what is selected rather than spill across a pipe.
            guard let current = wrappedCellCharIndex(atViewPoint: point),
                  let cell = tableCell(atRawOffset: current),
                  cell.blockIndex == anchorCell.blockIndex,
                  cell.row == anchorCell.row, cell.column == anchorCell.column else { continue }
            let lo = min(anchor, current), hi = max(anchor, current)
            setSelectedRange(NSRange(location: lo, length: hi - lo))
            updateWrappedCaret()
        }
        return true
    }

    // MARK: - Vertical movement

    /// The offset one visual line up or down inside the wrapped cell holding
    /// the caret, or nil when the caret isn't in one or the move leaves it.
    func wrappedCellVerticalOffset(lineDelta: Int) -> Int? {
        let selection = selectedRange()
        guard selection.length == 0, let tlm = textLayoutManager,
              let location = tlm.location(tlm.documentRange.location,
                                          offsetBy: selection.location),
              let fragment = tlm.textLayoutFragment(for: location)
                  as? DecoratedTextLayoutFragment,
              let paragraphStart = fragment.textElement?.elementRange?.location
        else { return nil }
        let base = tlm.offset(from: tlm.documentRange.location, to: paragraphStart)
        guard selection.location >= base,
              let local = fragment.cellWrapOffset(
                  fromParagraphOffset: selection.location - base, lineDelta: lineDelta)
        else { return nil }
        return base + local
    }

    public override func moveUp(_ sender: Any?) {
        guard let offset = wrappedCellVerticalOffset(lineDelta: -1) else {
            super.moveUp(sender)
            return
        }
        setSelectedRange(NSRange(location: offset, length: 0))
    }

    public override func moveDown(_ sender: Any?) {
        guard let offset = wrappedCellVerticalOffset(lineDelta: 1) else {
            super.moveDown(sender)
            return
        }
        setSelectedRange(NSRange(location: offset, length: 0))
    }
}
