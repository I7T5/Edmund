import AppKit

// MARK: - Lazy Styling: idle drain + scroll promotion
//
// The dirty flush styles only blocks near the viewport synchronously and
// leaves the rest marked `isStyled == false` (base attributes after a load,
// or briefly-stale styling after an offscreen structural change). Two
// mechanisms converge the document:
//
// - The idle drain: time-budgeted main-thread slices restyling unstyled
//   blocks until none remain, so document height settles and offscreen
//   content is ready before the user gets there.
// - Scroll promotion: when the clip view scrolls, unstyled blocks entering
//   the viewport window are styled synchronously so the user never sees raw
//   base-attributed text.

extension EditorTextView {

    /// Schedules the idle drain (coalesced; safe to call repeatedly).
    func scheduleProgressiveStyling() {
        guard !progressiveStylingScheduled else { return }
        progressiveStylingScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.progressiveStylingScheduled = false
            self?.drainStylingSlice()
        }
    }

    /// Restyles unstyled blocks for ~6 ms, then reschedules itself if any
    /// remain. Reads current state each slice, so edits/undo/load between
    /// slices are naturally accommodated. Internal so tests can drive the
    /// drain synchronously.
    func drainStylingSlice() {
        guard let ts = textStorage else { return }
        guard !isUpdating else { scheduleProgressiveStyling(); return }
        // Restyling marked text aborts IME composition — wait it out.
        guard !hasMarkedText() else { scheduleProgressiveStyling(); return }

        let start = ContinuousClock.now
        let budget = Duration.milliseconds(6)

        isUpdating = true
        let nsString = ts.string as NSString
        let cursor = selectedRange().location
        var remaining = false
        // Blocks restyled this slice need their TextKit 2 layout invalidated
        // afterward: restyling is attribute-only, and TextKit 2 doesn't
        // re-measure a fragment's geometry (height, first-line indent) for an
        // attribute-only change — so a deferred block whose styled height differs
        // from its base/estimated height would otherwise keep a stale fragment,
        // leaving an empty band on screen. `recomposeDirty` invalidates its
        // synchronously-styled blocks for the same reason.
        var restyled = IndexSet()
        // Explicit pool: styling churns through transient images/attributed
        // strings, and a caller may run many slices without a run-loop turn.
        autoreleasepool {
            ts.beginEditing()
            // Resume the scan where the last slice stopped (`drainCursor` is a
            // hint — edits shift indices, the wrap-around pass self-corrects).
            // Rescanning from 0 each slice made the drain quadratic: deep
            // slices burned their whole budget skipping styled blocks.
            let count = blocks.count
            var scanned = 0
            var idx = min(drainCursor, max(0, count - 1))
            while scanned < count {
                if idx >= count { idx = 0 }
                if !blocks[idx].isStyled {
                    let cursorInBlock: Int? = (idx == activeBlockIndex)
                        ? max(0, cursor - blocks[idx].range.location) : nil
                    restyleBlock(idx, cursorInBlock: cursorInBlock)
                    blocks[idx].isStyled = true
                    restyled.insert(idx)
                    let sep = blocks[idx].range.upperBound
                    if sep < nsString.length && nsString.character(at: sep) == 0x0A {
                        ts.setAttributes(baseAttributes, range: NSRange(location: sep, length: 1))
                    }
                    if ContinuousClock.now - start > budget {
                        remaining = true
                        idx += 1
                        break
                    }
                }
                idx += 1
                scanned += 1
            }
            drainCursor = idx
            ts.endEditing()
        }

        if let tlm = textLayoutManager {
            for idx in restyled where idx < blocks.count {
                if let range = blockTextRange(blocks[idx].range, tlm) {
                    tlm.invalidateLayout(for: range)
                }
            }
        }
        isUpdating = false

        if remaining { scheduleProgressiveStyling() }
    }

    /// Styles any unstyled blocks inside the current viewport window. Forces a
    /// viewport layout first because callers may run before the next layout
    /// pass (the viewport range would otherwise be stale).
    func promoteVisibleUnstyledBlocks() {
        textLayoutManager?.textViewportLayoutController.layoutViewport()
        guard let bounds = syncStylingBlockRange() else { return }
        let unstyled = IndexSet(bounds.filter { !blocks[$0].isStyled })
        guard !unstyled.isEmpty else { return }
        recomposeDirty(unstyled, cursorInRaw: selectedRange().location)
    }

    /// Observes clip-view scrolling for promotion. Called from
    /// `viewDidMoveToWindow`.
    func installScrollPromotionObserver() {
        guard let clipView = enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        // viewDidMoveToWindow can fire more than once; keep one observation.
        NotificationCenter.default.removeObserver(
            self, name: NSView.boundsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    @objc private func clipViewBoundsDidChange(_ note: Notification) {
        // Promotion forces a viewport layout and may restyle blocks (changing
        // their heights). Running that synchronously inside the scroll
        // notification fights the momentum scroll and makes the viewport
        // bounce. Defer to the next run-loop turn (coalesced), so each scroll
        // tick just scrolls and styling catches up between ticks.
        guard !isUpdating, !pendingPromotion else { return }
        pendingPromotion = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingPromotion = false
            guard !self.isUpdating else { return }
            self.promoteVisibleUnstyledBlocks()
        }
    }
}
