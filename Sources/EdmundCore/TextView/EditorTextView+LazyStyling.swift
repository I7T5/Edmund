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

        if remaining {
            scheduleProgressiveStyling()
        } else {
            scheduleFullLayoutSettle()
        }
    }

    /// TextKit 2 only gives a fragment a real frame once it's laid out;
    /// everything else is a height *estimate*, and estimate corrections are
    /// what make the scroller jump, drag-selection autoscroll oscillate, and
    /// scroll targets land wrong. For small documents we can afford to lay
    /// everything out once styling has converged, so no estimates remain.
    /// `ensureLayout` is incremental — already-laid-out fragments are skipped
    /// — so repeated settles after edits only re-lay the invalidated blocks.
    /// (Large documents keep viewport-based layout: a full layout there is
    /// the process-killing path that motivated `scrollRangeToVisible`'s
    /// override.)
    ///
    /// Runs on the next run-loop pass, wrapped in `preservingViewportAnchor`:
    /// correcting estimates *above* the viewport shifts every laid-out
    /// position below them, so doing it synchronously inside a caller's own
    /// anchored restyle would poison that caller's before/after measurement.
    func scheduleFullLayoutSettle() {
        guard !fullLayoutSettleScheduled else { return }
        fullLayoutSettleScheduled = true
        // RunLoop.perform, not DispatchQueue.main.async, so tests can drain it
        // with `RunLoop.main.run(until:)`.
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fullLayoutSettleScheduled = false
                guard !self.isUpdating, !self.hasMarkedText(),
                      let tlm = self.textLayoutManager else { return }
                self.repairContentAboveOrigin()
                guard (self.textStorage?.length ?? 0) <= Self.fullLayoutMaxLength,
                      self.blocks.allSatisfy({ $0.isStyled }) else { return }
                self.preservingViewportAnchor {
                    tlm.ensureLayout(for: tlm.documentRange)
                }
            }
        }
    }

    /// TextKit 2 can leave the document's first fragment at a *negative* y
    /// after edits near the top: layout proceeding upward from a viewport
    /// anchor with a wrong height estimate assigns origins above 0, and
    /// nothing renormalizes them. The symptom is the first line sitting above
    /// the visible area with the scroller already at the top — unreachable.
    /// Repair: re-lay from the document start (anchoring the first fragment
    /// back at y 0) inside `preservingViewportAnchor`, which compensates the
    /// clip origin so what the user is looking at doesn't move — and the
    /// content above becomes scrollable again.
    func repairContentAboveOrigin() {
        guard let tlm = textLayoutManager else { return }
        var firstMinY: CGFloat?
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) {
            firstMinY = $0.layoutFragmentFrame.minY
            return false
        }
        guard let firstMinY, firstMinY < -0.5 else { return }

        // Bound the re-lay to start→viewport-end (the bug only manifests with
        // the viewport near the top, so this is small); bail on huge spans
        // rather than risk the full-document layout cost on a large file.
        var end = tlm.documentRange.endLocation
        if let vp = tlm.textViewportLayoutController.viewportRange {
            end = vp.endLocation
        }
        guard tlm.offset(from: tlm.documentRange.location, to: end) <= 60_000,
              let range = NSTextRange(location: tlm.documentRange.location, end: end)
        else { return }
        Log.info("repairing content above origin: firstMinY=\(firstMinY)",
                 category: .compose)
        preservingViewportAnchor {
            tlm.invalidateLayout(for: range)
            tlm.ensureLayout(for: range)
        }
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
