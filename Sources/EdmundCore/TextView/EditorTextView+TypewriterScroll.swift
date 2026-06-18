import AppKit

/// Viewport stability: typewriter centering, viewport-top anchoring across
/// height-changing restyles, and a fragment-based `scrollRangeToVisible` that
/// avoids AppKit's TextKit 2 scroll-to-range (which kills the process on large
/// documents). The `typewriterModeEnabled` stored flag lives on the main class.
extension EditorTextView {

    /// Runs `body` (which restyles the active block, changing its height) while
    /// pinning the line at the TOP of the viewport to the same screen position
    /// — so the part of the document the user is looking at doesn't move, even
    /// when the height change (or a lazy-layout height estimate) is above the
    /// caret. Anchoring the viewport top rather than the caret is what removes
    /// the residual lurch: a caret anchor holds the caret but lets the content
    /// above it slide.
    ///
    /// Reliability: `layoutViewport()` first guarantees the on-screen fragments
    /// are laid out, so the top fragment's character offset is correct; both
    /// samples then go through `lineRect` (which forces layout) for a
    /// consistent measurement. A mis-measure degrades to no scroll — never a
    /// yank or a jump to the document start.
    func preservingViewportAnchor(_ body: () -> Void) {
        guard let scrollView = enclosingScrollView, let tlm = textLayoutManager else {
            body(); return
        }
        tlm.textViewportLayoutController.layoutViewport()
        let visible = scrollView.contentView.bounds
        let topPoint = CGPoint(x: 0, y: visible.minY - textContainerOrigin.y)
        guard let frag = tlm.textLayoutFragment(for: topPoint) else { body(); return }
        let anchorOffset = tlm.offset(from: tlm.documentRange.location,
                                      to: frag.rangeInElement.location)
        let beforeY = lineRect(forCharacterAt: anchorOffset)?.minY

        body()

        guard let beforeY, let afterY = lineRect(forCharacterAt: anchorOffset)?.minY else { return }
        let delta = afterY - beforeY
        guard abs(delta) > 0.5 else { return }
        let newY = max(0, visible.origin.y + delta)
        scrollView.contentView.scroll(to: NSPoint(x: visible.origin.x, y: newY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Runs a restyle (`body`) while keeping the viewport visually stable: in
    /// typewriter mode it re-centers on the caret afterward; otherwise it pins
    /// the viewport top (`preservingViewportAnchor`) so content above the edit
    /// doesn't shift. The selection-driven cursor-move path uses the same
    /// split inline; this wraps it for the indent path's two call sites.
    func stabilizingViewport(_ body: () -> Void) {
        if typewriterModeEnabled {
            body()
            scrollCursorToCenter()
        } else {
            preservingViewportAnchor(body)
        }
    }

    /// Scrolls the view so the cursor's line fragment is vertically centered
    /// in the visible area.
    func scrollCursorToCenter() {
        guard typewriterModeEnabled else { return }
        guard let scrollView = enclosingScrollView,
              let lineRect = caretLineRect() else { return }
        let cursorY = lineRect.midY + textContainerOrigin.y

        let visibleHeight = scrollView.contentView.bounds.height
        let targetY = cursorY - visibleHeight / 2
        let maxY = max(0, frame.height - visibleHeight)
        let clampedY = min(max(0, targetY), maxY)

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The caret line's rect in text-container coordinates (TextKit 2: lays
    /// out only the caret's fragment, positions above are estimated).
    private func caretLineRect() -> CGRect? {
        lineRect(forCharacterAt: selectedRange().location)
    }

    /// The line rect for the character at `offset`, in text-container
    /// coordinates. Lays out only the offset's own fragment — forcing layout
    /// from the document start would lay out (and could OOM on) the whole 1–2
    /// MB document for a deep caret. For carets in or near the viewport the
    /// position is exact; for far jumps it may be a TextKit 2 estimate that
    /// the scroll anchoring + promotion settle once the region is reached.
    func lineRect(forCharacterAt offset: Int) -> CGRect? {
        guard let tlm = textLayoutManager else { return nil }
        guard let loc = tlm.location(tlm.documentRange.location, offsetBy: offset)
        else { return nil }
        tlm.ensureLayout(for: NSTextRange(location: loc))
        guard let fragment = tlm.textLayoutFragment(for: loc) else { return nil }
        let frame = fragment.layoutFragmentFrame

        guard let paraStart = fragment.textElement?.elementRange?.location else { return frame }
        let offsetInPara = tlm.offset(from: paraStart, to: loc)
        let line = fragment.textLineFragments.first {
            NSLocationInRange(offsetInPara, $0.characterRange)
        } ?? fragment.textLineFragments.last
        guard let line else { return frame }
        return line.typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY)
    }

    /// AppKit's TextKit 2 implementation of scroll-to-range kills the process
    /// on large documents (observed reproducibly at ~1.5 MB; silent kill, no
    /// crash report). NSTextView calls it internally after every insertion
    /// (caret autoscroll), so replace it with the minimal fragment-based
    /// scroll: lay out just the target's fragment and move the clip view.
    public override func scrollRangeToVisible(_ range: NSRange) {
        guard let scrollView = enclosingScrollView else { return }
        // Bound the range by its two ends so an extended selection follows the
        // end being modified rather than always its start.
        let visible = scrollView.contentView.bounds
        guard let startRect = lineRect(forCharacterAt: range.location) else { return }
        let endRect = range.length > 0
            ? (lineRect(forCharacterAt: range.upperBound) ?? startRect) : startRect
        let top = min(startRect.minY, endRect.minY) + textContainerOrigin.y
        let bottom = max(startRect.maxY, endRect.maxY) + textContainerOrigin.y
        let margin: CGFloat = 8

        var targetY = visible.origin.y
        if top < visible.minY {
            targetY = top - margin
        } else if bottom > visible.maxY {
            // Prefer keeping the bottom edge visible; fall back to the top if
            // the range is taller than the viewport.
            targetY = min(bottom + margin - visible.height, top - margin)
        } else {
            return  // already visible
        }
        let maxY = max(0, frame.height - visible.height)
        let clampedY = min(max(0, targetY), maxY)
        scrollView.contentView.scroll(to: NSPoint(x: visible.origin.x, y: clampedY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
