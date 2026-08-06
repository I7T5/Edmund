import AppKit

// MARK: - Content width (centered reading column)
//
// The text column has a physical maximum width (set in cm in Settings and
// converted to points using the display's real PPI). Windows wider than the
// cap get symmetric side margins that center the column; narrower windows
// fill edge-to-edge as usual. This is CSS `max-width` semantics: the cap is
// an absolute physical size, not a fraction of the window or the screen, so
// the column doesn't widen when you make the window bigger.

extension EditorTextView {

    /// Padding applied on each side of the text column at all window sizes.
    static let contentBaseInset: CGFloat = 24

    /// Padding above the first line and below the last one, outside typewriter
    /// scroll. `Document` seeds the text view with this value.
    public static let contentBaseVerticalInset: CGFloat = 18

    /// Reserves scrolling room past the document's ends: half a viewport below
    /// the last line always (so the line being written is never pinned to the
    /// window's bottom edge), and half a viewport above the first line while
    /// typewriter scroll is on (so the opening screenful can reach center).
    ///
    /// The room is bought as document-view height — `textContainerInset` grows
    /// the frame by twice its height, and `textContainerOrigin` (overridden)
    /// decides how that space splits between the ends. It is deliberately NOT
    /// `NSScrollView.contentInsets`: AppKit restricts hit-testing to the
    /// content area, i.e. the scroll view's frame *minus* its insets, so
    /// reserving half a viewport at each end left a zero-height live area and
    /// the whole window stopped responding to clicks. Padding inside the
    /// document view keeps every point of the window inside the text view,
    /// where a click in the blank band lands on the nearest character.
    ///
    /// The top bars are the exception, and go through `contentInsets` — see
    /// `applyTopBarInset`. That objection does not apply to them: the band they
    /// cost is the band they cover, so the live area only loses what the reader
    /// could not click anyway.
    public func updateScrollOverscroll() {
        guard let scrollView = enclosingScrollView else { return }
        let clipHeight = scrollView.contentView.bounds.height
        guard clipHeight > 0 else { return }
        applyTopBarInset(additionalTopInset, in: scrollView)
        // Half of what the reader can *see*, not half the clip: the bars cover
        // the top `viewportTopInset` of it, and the scroll range already starts
        // at -inset, which supplies that much of the run-up for free.
        let top = typewriterModeEnabled ? visibleContentHeight / 2 : 0
        let bottom = clipHeight / 2
        guard abs(top - overscrollTopPad) > 0.5
                || abs(bottom - overscrollBottomPad) > 0.5 else { return }
        let base = textContainerInset.height - (overscrollTopPad + overscrollBottomPad) / 2
        let shift = top - overscrollTopPad
        overscrollTopPad = top
        overscrollBottomPad = bottom
        textContainerInset = NSSize(width: textContainerInset.width,
                                    height: base + (top + bottom) / 2)
        // The frame follows the inset only on an explicit `sizeToFit` — until
        // then the scroll range still reflects the old padding, and the first
        // centering after a toggle would clamp against it.
        sizeToFit()
        // The text just moved down by `shift` in document coordinates; follow
        // it so the reader keeps looking at the same line.
        let origin = scrollView.contentView.bounds.origin
        let y = clampedScrollY(origin.y + shift)
        guard abs(y - origin.y) > 0.5 else { return }
        scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The height of the chrome bars stacked over the top of the scroll view
    /// (format bar, find bar), as a real `contentInsets.top`.
    ///
    /// AppKit does *not* shrink the clip view for a content inset — the clip
    /// still spans the whole scroll view and the document scrolls under the
    /// band. What the inset changes is the scroll range: its top end moves from
    /// 0 to `-inset`, so the document can rest that far down with no extra
    /// document height. Every conversion between clip coordinates and "the top
    /// of what the reader can actually see" therefore has to add this.
    var viewportTopInset: CGFloat { enclosingScrollView?.contentInsets.top ?? 0 }

    /// The part of the clip view the bars leave visible.
    var visibleContentHeight: CGFloat {
        guard let clip = enclosingScrollView?.contentView else { return 0 }
        return max(0, clip.bounds.height - viewportTopInset)
    }

    /// Mirrors `additionalTopInset` onto the scroll view and slides the document
    /// down by the same amount.
    ///
    /// Both halves matter. The inset alone would only widen the scroll range —
    /// the document would keep its old origin and the bar would simply cover the
    /// top lines. Following it with the matching scroll is what makes a bar
    /// appearing *push* the text down and a bar closing pull it back up, with
    /// the reader's line held at the same place on screen throughout.
    private func applyTopBarInset(_ inset: CGFloat, in scrollView: NSScrollView) {
        let delta = inset - scrollView.contentInsets.top
        guard abs(delta) > 0.5 else { return }
        // Sampled *before* the inset changes. Shrinking the inset immediately
        // re-clamps the clip view against the narrower range, so reading the
        // origin afterwards returns a position that has already absorbed part
        // of `delta` — subtracting it again scrolled the document down by the
        // bar's height on the way out instead of back up.
        let origin = scrollView.contentView.bounds.origin
        // Otherwise AppKit recomputes the insets from the window's titlebar and
        // stamps on ours.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: inset, left: 0, bottom: 0, right: 0)
        // Clamped after, though — the permitted range depends on the new inset.
        let y = clampedScrollY(origin.y - delta)
        guard abs(y - origin.y) > 0.5 else { return }
        scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// `updateScrollOverscroll` on the next run-loop hop. It resizes the text
    /// view, which must not happen from inside the layout pass `setFrameSize`
    /// runs in.
    func scheduleOverscrollUpdate() {
        guard enclosingScrollView != nil, !overscrollUpdateScheduled else { return }
        overscrollUpdateScheduled = true
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.overscrollUpdateScheduled = false
                self.updateScrollOverscroll()
            }
        }
    }

    /// The symmetric horizontal inset for a given view width and max-column width.
    /// `maxContentWidth == .greatestFiniteMagnitude` → base inset only (fills the window).
    /// When the window is too narrow to fit `maxContentWidth`, the column also fills.
    public static func horizontalInset(viewWidth: CGFloat, maxContentWidth: CGFloat) -> CGFloat {
        let available = viewWidth - 2 * contentBaseInset
        guard available > maxContentWidth else { return contentBaseInset }
        return contentBaseInset + (available - maxContentWidth) / 2
    }

    /// Recomputes the horizontal text inset from the current bounds + max-column cap,
    /// preserving the vertical inset. Usually no recompose — only the inset
    /// changes and TextKit 2 reflows wrapped text on its own. The exception is
    /// image overlays: their scaled-to-fit size is baked into the styled
    /// attribute at render time (§4 fragmentOverlay), not recomputed at draw
    /// time, so a column narrower than an already-rendered image needs those
    /// blocks restyled to shrink it.
    public func updateContentInset() {
        let target = Self.horizontalInset(viewWidth: bounds.width,
                                          maxContentWidth: maxContentWidthPoints)
        let widthChanged = abs(textContainerInset.width - target) > 0.5
        if widthChanged {
            textContainerInset = NSSize(width: target, height: textContainerInset.height)
        }
        // Tracks the clip height, so it has to be rechecked on every resize —
        // but scheduled, for the same reason as the ruler below: this runs
        // inside `setFrameSize`, and the overscroll pass resizes the view.
        scheduleOverscrollUpdate()
        // This margin is where the line numbers live, so resizing it can push
        // them out to the window-edge gutter or bring them back beside the text.
        // Checked even when the inset held steady: the document's digit count
        // grows on its own, and this is the cheapest place that sees both.
        // Scheduled rather than applied — this runs inside `setFrameSize`, and
        // re-tiling the scroll view from inside its own layout is a crash.
        scheduleLineNumberPlacementUpdate()
        // Image overlays are sized against the column width only, so a
        // vertical-only change needs no recompose.
        guard widthChanged else { return }

        let imageBlocks = IndexSet(blocks.indices.filter { blocks[$0].content.contains("![") })
        guard !imageBlocks.isEmpty else { return }
        for idx in imageBlocks { blocks[idx].isStyled = false }
        recomposeDirty(imageBlocks, cursorInRaw: currentCursorInRaw(), settingSelection: true)
    }

    /// Recompute the centered inset as the view width changes (window resize).
    public override func setFrameSize(_ newSize: NSSize) {
        // A document shorter than the window still has to cover it: the area
        // below a short text view belongs to the clip view, which swallows
        // clicks instead of putting the caret on the nearest character.
        var size = newSize
        if let clipHeight = enclosingScrollView?.contentView.bounds.height {
            size.height = max(size.height, clipHeight)
        }
        super.setFrameSize(size)
        updateContentInset()
    }

}
