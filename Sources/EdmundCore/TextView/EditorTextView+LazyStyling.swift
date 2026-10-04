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
//   the viewport window are styled so the user never sees raw
//   base-attributed text. Promotion stays active during live scrolling;
//   only the idle drain and full-layout settle wait for scroll quiescence.

extension EditorTextView {

    /// Schedules the idle drain (coalesced; safe to call repeatedly). Paused
    /// while the user is actively scrolling — the drain reschedules every
    /// run-loop pass and competes with the scroll for the main thread; the
    /// scroll-quiescence flip resumes it. Explicit `drainStylingSlice()` calls
    /// bypass the live-scroll gate for tests, but still pause while hidden.
    func scheduleProgressiveStyling() {
        guard !progressiveStylingScheduled else { return }
        guard isEditorPresentationActive, !isScrollingActive else { return }
        progressiveStylingScheduled = true
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.progressiveStylingScheduled = false
                guard self.isEditorPresentationActive, !self.isScrollingActive else { return }
                self.drainStylingSlice()
            }
        }
    }

    /// A cooperative target, not a hard deadline: one block and TextKit's
    /// transaction completion cannot be interrupted. Reserve the previous
    /// completion cost before admitting another block; measure the whole call.
    static let backgroundStylingBudget: Duration = .milliseconds(3)

    /// Idle work can amortize expensive, indivisible TextKit completion up to
    /// 6 ms. A fixed 3 ms target collapsed to one block per transaction on a
    /// 1 MB document (22 s vs 1.7 s). Live scrolling never schedules this drain;
    /// its optional margin prefetch still uses the fixed 3 ms target.
    var idleStylingBudget: Duration {
        min(.milliseconds(6), max(Self.backgroundStylingBudget,
                                 stylingSlicePreparationEstimate
                                 + stylingSliceCompletionEstimate + .milliseconds(2)))
    }

    func drainStylingSlice(budget: Duration? = nil) {
        guard isEditorPresentationActive else { return }
        guard !isUpdating, !hasMarkedText() else { scheduleProgressiveStyling(); return }
        stylePendingBlocks(in: nil, budget: budget ?? idleStylingBudget)
        if unstyledBlockCount > 0 { scheduleProgressiveStyling() }
        else { scheduleFullLayoutSettle() }
    }

    /// `candidates == nil` drains the document. Scroll prefetch supplies only
    /// the viewport margin; neither path scans already-styled paragraphs.
    private func stylePendingBlocks(in candidates: IndexSet?, budget: Duration) {
        guard let ts = textStorage, unstyledBlockCount > 0 else { return }
        var pending = candidates.map { unstyledBlockIndexes.intersection($0) }
        guard pending?.isEmpty != true else { return }
        let start = ContinuousClock.now
        let workBudget = max(.zero, budget - stylingSliceCompletionEstimate)
        var processingEnd = start
        var preparationEnd = start
        var restyled = IndexSet()
        let cursor = selectedRange().location
        isUpdating = true
        preservingViewportAnchor {
            preparationEnd = ContinuousClock.now
            autoreleasepool {
                ts.beginEditing()
                while let idx = pending == nil ? unstyledBlockIndexes.first : pending?.first {
                    // Always make progress, even if anchoring used the budget.
                    guard restyled.isEmpty || ContinuousClock.now - start < workBudget else { break }
                    let cursorInBlock: Int? = (idx == activeBlockIndex)
                        ? max(0, cursor - blocks[idx].range.location) : nil
                    restyleBlock(idx, cursorInBlock: cursorInBlock)
                    setStyled(idx, true)
                    pending?.remove(idx)
                    restyled.insert(idx)
                }
                processingEnd = ContinuousClock.now
                ts.endEditing()
            }
            if let tlm = textLayoutManager {
                for idx in restyled where idx < blocks.count {
                    if let range = blockTextRange(blocks[idx].range, tlm) {
                        tlm.invalidateLayout(for: range)
                    }
                }
                tlm.textViewportLayoutController.layoutViewport()
            }
        }
        isUpdating = false
        let end = ContinuousClock.now
        lastStylingSliceDuration = end - start
        stylingSlicePreparationEstimate = preparationEnd - start
        stylingSliceCompletionEstimate = end - processingEnd
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
    /// Also skipped while the user is actively scrolling: a full-document
    /// layout mid-scroll is exactly the main-thread stall the scroll is
    /// trying to avoid. The quiescence resume path (a final drain slice →
    /// `scheduleFullLayoutSettle`) re-arms it once scrolling settles.
    ///
    /// Runs on the next run-loop pass, wrapped in `preservingViewportAnchor`:
    /// correcting estimates *above* the viewport shifts every laid-out
    /// position below them, so doing it synchronously inside a caller's own
    /// anchored restyle would poison that caller's before/after measurement.
    func scheduleFullLayoutSettle() {
        guard !fullLayoutSettleScheduled else { return }
        guard isEditorPresentationActive, !isScrollingActive else { return }
        fullLayoutSettleScheduled = true
        // RunLoop.perform, not DispatchQueue.main.async, so tests can drain it
        // with `RunLoop.main.run(until:)`.
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fullLayoutSettleScheduled = false
                guard !self.isUpdating, !self.hasMarkedText(), self.isEditorPresentationActive, !self.isScrollingActive,
                      let tlm = self.textLayoutManager else { return }
                self.repairContentAboveOrigin()
                guard (self.textStorage?.length ?? 0) <= Self.fullLayoutMaxLength,
                      self.unstyledBlockCount == 0 else { return }
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
        // Nothing to promote once the drain has styled everything — the usual
        // state after the first seconds. Skip the forced viewport layout then:
        // each one re-estimates the height of every unlaid-out paragraph, a
        // quarter of a large document's per-tick scroll cost.
        guard isEditorPresentationActive, unstyledBlockCount > 0 else { return }
        textLayoutManager?.textViewportLayoutController.layoutViewport()
        guard let bounds = syncStylingBlockRange(includingMargin: false) else { return }
        let unstyled = unstyledBlockIndexes.intersection(IndexSet(integersIn: bounds))
        guard !unstyled.isEmpty else { scheduleScrollPrefetch(); return }
        // Styling only: the text is unchanged, and the whole-document scan
        // covers its spelling. A synchronous recheck here queued behind the
        // scan's chunk in flight — 100–150 ms stalls in the first scroll
        // after opening a long file.
        stylingOnly { recomposeDirty(unstyled, cursorInRaw: selectedRange().location) }
        scheduleScrollPrefetch()
    }

    /// Synchronously styles every unstyled block from the document start
    /// through the block containing `offset`. `scrollCharacterToTop` needs the
    /// heights ABOVE its target to be final before it measures: an unstyled
    /// block lays out at base-attribute height, and when the drain/promotion
    /// styles it moments after the scroll, the re-measure slides the whole
    /// just-anchored viewport (drain invalidation is not scroll-compensated).
    /// Same per-block body as `drainStylingSlice`, without the time budget —
    /// callers bound the cost by capping `offset` instead.
    func ensureBlocksStyled(upTo offset: Int) {
        guard let ts = textStorage, !isUpdating, !hasMarkedText() else { return }
        guard let last = blocks.lastIndex(where: { $0.range.location <= offset }) else { return }
        let unstyled = (0...last).filter { !blocks[$0].isStyled }
        guard !unstyled.isEmpty else { return }
        isUpdating = true
        let cursor = selectedRange().location
        autoreleasepool {
            ts.beginEditing()
            for idx in unstyled {
                let cursorInBlock: Int? = (idx == activeBlockIndex)
                    ? max(0, cursor - blocks[idx].range.location) : nil
                restyleBlock(idx, cursorInBlock: cursorInBlock)
                setStyled(idx, true)
            }
            ts.endEditing()
        }
        if let tlm = textLayoutManager {
            for idx in unstyled where idx < blocks.count {
                if let range = blockTextRange(blocks[idx].range, tlm) {
                    tlm.invalidateLayout(for: range)
                }
            }
        }
        isUpdating = false
    }

    /// Observes clip-view scrolling for promotion. Called from
    /// `viewDidMoveToWindow`.
    func installScrollPromotionObserver() {
        guard let scrollView = enclosingScrollView else { return }
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        // viewDidMoveToWindow can fire more than once; keep one observation.
        for name in [NSView.boundsDidChangeNotification,
                     NSScrollView.willStartLiveScrollNotification,
                     NSScrollView.didEndLiveScrollNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(userScrollDidStart(_:)),
            name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(userScrollDidEnd(_:)),
            name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    }

    /// Keep the gate briefly after AppKit ends a live user scroll, so successive
    /// wheel gestures do not interleave background styling with the next scroll.
    private static let scrollQuiescenceDelay: TimeInterval = 0.25

    @objc private func clipViewBoundsDidChange(_ note: Notification) {
        // Bounds also change for caret centering, outline jumps, and viewport
        // compensation. Those must promote promptly without pausing styling.
        guard !isPromotingVisibleBlocks else { return }
        scheduleScrollPromotion()
    }

    @objc private func userScrollDidStart(_ note: Notification) {
        userScrollInProgress = true
        isScrollingActive = true
        scrollQuiescenceTimer?.invalidate()
        scrollQuiescenceTimer = nil
    }

    @objc private func userScrollDidEnd(_ note: Notification) {
        userScrollInProgress = false
        armScrollQuiescence()
    }

    private func armScrollQuiescence() {
        scrollQuiescenceTimer?.invalidate()
        scrollQuiescenceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.scrollQuiescenceDelay, repeats: false) { [weak self] _ in
            RunLoop.main.perform { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scrollQuiescenceTimer = nil
                    guard !self.userScrollInProgress else { return }
                    if self.isUpdating {
                        self.armScrollQuiescence()
                        return
                    }
                    self.isScrollingActive = false
                    self.scheduleScrollPromotion()
                    self.scheduleProgressiveStyling()
                }
            }
        }
    }

    /// One budgeted margin pass per promotion. Visible blocks were styled
    /// first; the rest is optional and never holds up that first paint.
    private func scheduleScrollPrefetch() {
        guard isEditorPresentationActive, !scrollPrefetchScheduled,
              unstyledBlockCount > 0 else { return }
        scrollPrefetchScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scrollPrefetchScheduled = false
                guard self.isEditorPresentationActive, !self.isUpdating, !self.hasMarkedText(),
                      self.unstyledBlockCount > 0,
                      let bounds = self.syncStylingBlockRange() else { return }
                self.isPromotingVisibleBlocks = true
                defer { self.isPromotingVisibleBlocks = false }
                self.stylePendingBlocks(in: IndexSet(integersIn: bounds),
                                        budget: Self.backgroundStylingBudget)
            }
        }
    }

    func scheduleScrollPromotion() {
        guard isEditorPresentationActive else { return }
        guard !scrollPromotionScheduled else { return }
        scrollPromotionScheduled = true
        // Common modes, not the default: dragging the scroller knob tracks the
        // mouse in `.eventTracking`, and a default-mode block would wait for
        // mouse-up — raw Markdown on screen for the whole drag.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scrollPromotionScheduled = false
                guard self.isEditorPresentationActive else { return }
                if self.isUpdating {
                    self.scheduleScrollPromotion()
                    return
                }
                self.isPromotingVisibleBlocks = true
                defer { self.isPromotingVisibleBlocks = false }
                self.promoteVisibleUnstyledBlocks()
            }
        }
    }
}
