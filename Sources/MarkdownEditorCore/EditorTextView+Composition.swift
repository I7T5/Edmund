import AppKit

// MARK: - Display Composition & Coordinate Mapping
//
// `recompose` rebuilds the whole text storage by styling every block and
// joining them; `recomposeIncremental` re-styles only the block(s) the cursor
// moved between, which is what runs on most edits. Because the text storage
// always equals the raw source (word-level rendering, no string stripping),
// the display↔raw coordinate mapping is the identity — the conversion helpers
// exist so call sites read clearly and stay correct if that ever changes.

extension EditorTextView {

    // MARK: - Display Composition
    //
    // Text storage content = rawSource, always.
    // Styling is attribute-only; the string never changes during recompose.

    /// Full recompose: replaces the entire text storage with `rawSource` in
    /// base attributes, then styles via the dirty flush — viewport-first when
    /// the editor is in a scroll view, everything synchronously otherwise.
    /// Used when rawSource was rebuilt (initial load, undo/redo, indent) and
    /// for content changes that bypass the edit path.
    func recompose(cursorInRaw: Int, selectionInRaw: NSRange? = nil) {
        guard let ts = textStorage else { return }

        isUpdating = true
        let fullRange = NSRange(location: 0, length: ts.length)
        ts.beginEditing()
        ts.replaceCharacters(in: fullRange,
                             with: NSAttributedString(string: rawSource,
                                                      attributes: baseAttributes))
        ts.endEditing()
        // Whole-document replacement; blocks are re-parsed by our callers.
        (ts as? EditorTextStorage)?.clearPendingEdit()
        isUpdating = false

        for i in blocks.indices { blocks[i].isStyled = false }
        recomposeDirty(IndexSet(blocks.indices), cursorInRaw: cursorInRaw,
                       selectionInRaw: selectionInRaw, settingSelection: true)
    }

    /// Dirty-set recompose: restyles exactly the given block indexes in place.
    /// Attribute-only — the storage string is never touched. This is the
    /// single styling path for edits, activation changes, and theme /
    /// appearance refreshes; `recompose` (string-replacing) remains only for
    /// paths that rebuild `rawSource` (load, undo, indent).
    ///
    /// `settingSelection` is true for selection-driven and whole-document
    /// callers (preserving the old recompose behavior); the edit path leaves
    /// the caret where NSTextView already placed it to avoid re-entrant
    /// selection notifications.
    func recomposeDirty(
        _ dirty: IndexSet,
        cursorInRaw: Int,
        selectionInRaw: NSRange? = nil,
        settingSelection: Bool = false
    ) {
        guard let ts = textStorage else { return }

        isUpdating = true

        let newActiveIndex = blockIndexForRawOffset(cursorInRaw)
        activeBlockIndex = newActiveIndex

        // Lazy rendering: a LARGE dirty set (load, theme change, a fence
        // absorbing half the document) is restyled synchronously only near
        // the viewport; the rest goes to the idle drain / scroll promotion.
        // Small sets — every normal interaction — are styled in full, so
        // user-visible state transitions are never deferred. Without a
        // scroll view (headless), everything is synchronous.
        var syncSet = dirty
        if dirty.count > 8, let bounds = syncStylingBlockRange() {
            syncSet = dirty.filteredIndexSet { bounds.contains($0) }
            if let active = newActiveIndex, dirty.contains(active) {
                syncSet.insert(active)
            }
        }
        let deferred = dirty.subtracting(syncSet)

        let nsString = ts.string as NSString
        ts.beginEditing()
        for idx in syncSet where idx < blocks.count {
            let cursorInBlock: Int? = (idx == newActiveIndex)
                ? max(0, cursorInRaw - blocks[idx].range.location) : nil
            restyleBlock(idx, cursorInBlock: cursorInBlock)
            blocks[idx].isStyled = true

            // Full recompose resets separator newlines to base attributes as
            // a side effect of rebuilding the whole string; do the same for
            // dirty blocks so stale paragraph styles can't linger on the `\n`
            // after e.g. a former callout.
            let sep = blocks[idx].range.upperBound
            if sep < nsString.length && nsString.character(at: sep) == 0x0A {
                ts.setAttributes(baseAttributes, range: NSRange(location: sep, length: 1))
            }
        }
        ts.endEditing()

        for idx in deferred where idx < blocks.count {
            blocks[idx].isStyled = false
        }

        displayRanges = blocks.map { $0.range }

        if settingSelection {
            if let rawSel = selectionInRaw, rawSel.length > 0 {
                let len = ts.length
                let displaySel = NSRange(
                    location: min(rawSel.location, len),
                    length: max(0, min(rawSel.upperBound, len) - min(rawSel.location, len))
                )
                setSelectedRange(displaySel)
            } else {
                let clamped = min(cursorInRaw, ts.length)
                setSelectedRange(NSRange(location: clamped, length: 0))
            }
        }

        typingAttributes = baseAttributes

        isUpdating = false

        if !deferred.isEmpty { scheduleProgressiveStyling() }
    }

    /// Incremental recompose: only re-styles the old and new active blocks.
    /// Used when the cursor moves between blocks without changing content.
    /// `settingSelection` is false when the caller already owns the caret (a
    /// user-driven cursor move) — re-setting it would trigger AppKit's
    /// scroll-the-selection-into-view, fighting typewriter centering.
    func recomposeIncremental(cursorInRaw: Int, selectionInRaw: NSRange? = nil,
                              settingSelection: Bool = true) {
        var dirty = IndexSet()
        if let oldIdx = activeBlockIndex, oldIdx < blocks.count { dirty.insert(oldIdx) }
        if let newIdx = blockIndexForRawOffset(cursorInRaw) { dirty.insert(newIdx) }
        recomposeDirty(dirty, cursorInRaw: cursorInRaw,
                       selectionInRaw: selectionInRaw, settingSelection: settingSelection)
    }

    /// Restyles every block in place (attribute-only). For theme and
    /// appearance changes: the string is unchanged but every attribute
    /// derives from the new theme/appearance.
    func recomposeAllDirty() {
        for i in blocks.indices { blocks[i].isStyled = false }
        recomposeDirty(IndexSet(blocks.indices),
                       cursorInRaw: currentCursorInRaw(),
                       settingSelection: true)
    }

    /// The block-index window to style synchronously: the TextKit 2 viewport
    /// plus a margin, or — before any layout exists (fresh load) — a window
    /// around the active block. Returns nil without a scroll view (headless):
    /// callers then style everything synchronously.
    func syncStylingBlockRange() -> ClosedRange<Int>? {
        guard enclosingScrollView != nil, !blocks.isEmpty,
              let tlm = textLayoutManager else { return nil }

        if let viewport = tlm.textViewportLayoutController.viewportRange {
            let docStart = tlm.documentRange.location
            let start = tlm.offset(from: docStart, to: viewport.location)
            let end = tlm.offset(from: docStart, to: viewport.endLocation)
            if let s = blockIndexForRawOffset(start),
               let e = blockIndexForRawOffset(max(start, end)) {
                let margin = max(16, e - s + 1)
                return max(0, s - margin) ... min(blocks.count - 1, e + margin)
            }
        }
        // No viewport yet (first layout hasn't happened): style a generous
        // window around the cursor; the drain and scroll promotion cover the rest.
        let anchor = activeBlockIndex ?? 0
        return max(0, anchor - 200) ... min(blocks.count - 1, anchor + 200)
    }

    /// Recalculates displayRanges from current blocks.
    /// With word-level rendering, display ranges = raw block ranges.
    func recalcDisplayRanges() {
        displayRanges = blocks.map { $0.range }
    }

    // MARK: - Coordinate Mapping
    //
    // With text storage = rawSource, display offset = raw offset (identity).

    /// Binary search over the (sorted, adjacent) block ranges. An offset at a
    /// block's `upperBound` — the trailing `\n` separator — belongs to that
    /// block; offsets past the last block clamp to it.
    func blockIndexForRawOffset(_ rawOffset: Int) -> Int? {
        guard !blocks.isEmpty else { return nil }
        var lo = 0
        var hi = blocks.count - 1
        // First block whose inclusive upper bound reaches the offset.
        while lo < hi {
            let mid = (lo + hi) / 2
            if blocks[mid].range.upperBound < rawOffset {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    func displayOffsetToRawOffset(_ displayOffset: Int) -> Int {
        return displayOffset
    }

    func rawOffsetToDisplayOffset(_ rawOffset: Int) -> Int {
        return rawOffset
    }

    func displayRangeToRawRange(_ displayRange: NSRange) -> NSRange {
        return displayRange
    }
}
