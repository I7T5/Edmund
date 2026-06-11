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

    /// Full recompose: replaces the entire text storage. Used for initial load,
    /// content changes (undo/redo, loadContent), font/appearance changes.
    func recompose(cursorInRaw: Int, selectionInRaw: NSRange? = nil) {
        isUpdating = true

        activeBlockIndex = blockIndexForRawOffset(cursorInRaw)

        // Build styled attributed string from rawSource.
        let composed = NSMutableAttributedString(string: rawSource, attributes: baseAttributes)

        for (i, block) in blocks.enumerated() {
            guard block.range.upperBound <= composed.length else { continue }

            let cursorInBlock: Int?
            if i == activeBlockIndex {
                cursorInBlock = max(0, cursorInRaw - block.range.location)
            } else {
                cursorInBlock = nil
            }

            let styled = styleBlock(block.content, cursorPosition: cursorInBlock)

            styled.enumerateAttributes(
                in: NSRange(location: 0, length: styled.length), options: []
            ) { attrs, range, _ in
                let tsRange = NSRange(
                    location: range.location + block.range.location,
                    length: range.length
                )
                guard tsRange.upperBound <= composed.length else { return }
                composed.setAttributes(attrs, range: tsRange)
            }
        }

        let fullRange = NSRange(location: 0, length: textStorage!.length)
        textStorage?.beginEditing()
        textStorage?.replaceCharacters(in: fullRange, with: composed)
        textStorage?.endEditing()

        displayRanges = blocks.map { $0.range }

        if let rawSel = selectionInRaw, rawSel.length > 0 {
            let len = textStorage!.length
            let displaySel = NSRange(
                location: min(rawSel.location, len),
                length: max(0, min(rawSel.upperBound, len) - min(rawSel.location, len))
            )
            setSelectedRange(displaySel)
        } else {
            let clamped = min(cursorInRaw, textStorage!.length)
            setSelectedRange(NSRange(location: clamped, length: 0))
        }

        typingAttributes = baseAttributes

        isUpdating = false
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

        let nsString = ts.string as NSString
        ts.beginEditing()
        for idx in dirty where idx < blocks.count {
            let cursorInBlock: Int? = (idx == newActiveIndex)
                ? max(0, cursorInRaw - blocks[idx].range.location) : nil
            restyleBlock(idx, cursorInBlock: cursorInBlock)

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
    }

    /// Incremental recompose: only re-styles the old and new active blocks.
    /// Used when the cursor moves between blocks without changing content.
    func recomposeIncremental(cursorInRaw: Int, selectionInRaw: NSRange? = nil) {
        var dirty = IndexSet()
        if let oldIdx = activeBlockIndex, oldIdx < blocks.count { dirty.insert(oldIdx) }
        if let newIdx = blockIndexForRawOffset(cursorInRaw) { dirty.insert(newIdx) }
        recomposeDirty(dirty, cursorInRaw: cursorInRaw,
                       selectionInRaw: selectionInRaw, settingSelection: true)
    }

    /// Restyles every block in place (attribute-only). For theme and
    /// appearance changes: the string is unchanged but every attribute
    /// derives from the new theme/appearance.
    func recomposeAllDirty() {
        recomposeDirty(IndexSet(blocks.indices),
                       cursorInRaw: currentCursorInRaw(),
                       settingSelection: true)
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
