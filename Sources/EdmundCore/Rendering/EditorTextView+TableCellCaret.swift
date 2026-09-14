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
    func wrappedCellRects(for range: NSRange) -> [NSRect] {
        guard let tlm = textLayoutManager,
              let storage = textStorage, storage.length > 0,
              range.location >= 0, range.upperBound <= storage.length,
              let location = tlm.location(tlm.documentRange.location,
                                          offsetBy: range.location),
              let fragment = tlm.textLayoutFragment(for: location)
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
    func wrappedCellCaretRect() -> NSRect? {
        let selection = selectedRange()
        guard selection.length == 0,
              var rect = wrappedCellRects(for: selection).first else { return nil }
        rect.size.width = 1
        return rect
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
        guard wrappedCaretOn, window?.firstResponder === self,
              let caret = wrappedCellCaretRect(), caret.intersects(rect) else { return }
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
        if let stale = wrappedCaretRect { setNeedsDisplay(stale) }
        let band = rects.isEmpty ? nil : chromeBand(rects)
        wrappedCaretRect = band
        if let band { setNeedsDisplay(band) }

        guard !rects.isEmpty else {
            guard wrappedCaretTimer != nil else { return }
            wrappedCaretTimer?.invalidate()
            wrappedCaretTimer = nil
            insertionPointColor = accentColor
            return
        }
        insertionPointColor = .clear
        // Clearing the colour is not enough on macOS 15: the live insertion-point
        // view keeps the colour it was started with, so an accent caret carried
        // in from a non-wrapped cell paints one frame at the collapsed
        // hidden-character x (the cell's start) before the custom caret shows —
        // the flash. Turn the insertion point off outright, here at the one place
        // every caret-into-a-wrapped-cell update passes through, so the click and
        // the async selection-change path are both covered.
        updateInsertionPointStateAndRestartTimer(false)
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
        // Kill AppKit's caret *before* placing the selection. When the previous
        // click left the caret in a non-wrapped cell, `updateWrappedCaret`
        // restored the accent colour and AppKit's insertion point is live and
        // blinking — so `setSelectedRange` here repaints it once, at the wrapped
        // cell's hidden-character x (which diverges from the drawn text on a
        // header row), before the custom caret takes over: the flash. Clearing
        // the colour is not enough on its own — the live insertion-point view
        // paints a frame with the colour it already had — so also turn the
        // insertion point off outright. (The first click into a table doesn't
        // flash because the view is only becoming first responder then, with no
        // live caret yet; a repeat click does, which is the case this covers.)
        insertionPointColor = .clear
        updateInsertionPointStateAndRestartTimer(false)
        if window.firstResponder !== self { window.makeFirstResponder(self) }
        suppressTypewriterCentering = true
        defer { suppressTypewriterCentering = false }
        setSelectedRange(NSRange(location: anchor, length: 0))
        // `setSelectedRange` restarts AppKit's insertion point, which would paint
        // it once at the hidden-character x; turn it back off now that the
        // selection has moved, before the custom caret is drawn.
        updateInsertionPointStateAndRestartTimer(false)
        updateWrappedCaret()
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }
            let point = convert(e.locationInWindow, from: nil)
            // Stay inside the anchor's cell: a point that leaves it (another cell,
            // the pad, off the text) maps to nil or a different cell and is
            // ignored, so the selection never spills across a pipe.
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
