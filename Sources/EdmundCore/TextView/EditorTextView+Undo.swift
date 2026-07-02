import AppKit

// MARK: - Custom Undo/Redo
//
// Custom undo stack operating on rawSource snapshots.  Completely bypasses
// NSTextView's built-in undo (allowsUndo = false) because recompose
// replaces the entire text storage, invalidating position-based undo.

extension EditorTextView {

    @objc public func undo(_ sender: Any?) {
        performUndo()
    }

    @objc public func redo(_ sender: Any?) {
        performRedo()
    }

    func classifyEdit(range: NSRange, replacement: String) -> EditType {
        if replacement == "\n" { return .other }  // Enter always starts a new group
        if replacement.count == 1 && range.length == 0 { return .insert }
        if replacement.isEmpty && range.length == 1 { return .delete }
        return .other
    }

    /// Push an undo snapshot if this edit starts a new coalescing group.
    func recordUndoIfNeeded(editRange: NSRange, replacement: String) {
        let editType = classifyEdit(range: editRange, replacement: replacement)

        let shouldPush = undoStack.isEmpty
            || editType == .other
            || editType != lastEditType
            || activeBlockIndex != lastEditBlockIndex

        if shouldPush {
            undoStack.append(UndoSnapshot(rawSource: rawSource, cursorInRaw: currentCursorInRaw()))
            redoStack.removeAll()
        }

        lastEditType = editType
        lastEditBlockIndex = activeBlockIndex
    }

    func performUndo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(UndoSnapshot(rawSource: rawSource, cursorInRaw: currentCursorInRaw()))
        restoreSnapshot(snapshot)
    }

    func performRedo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(UndoSnapshot(rawSource: rawSource, cursorInRaw: currentCursorInRaw()))
        restoreSnapshot(snapshot)
    }

    /// The single contiguous span that differs between two strings, as the
    /// replaced range in `old` (UTF-16) plus its replacement text from `new`.
    /// nil when the strings are equal. Boundaries never split a surrogate
    /// pair, so the result is always safe to select or restyle.
    nonisolated static func textDiff(old: String, new: String) -> (oldRange: NSRange, replacement: String)? {
        let o = old as NSString
        let n = new as NSString
        guard !o.isEqual(to: new) else { return nil }

        var prefix = 0
        let maxPrefix = min(o.length, n.length)
        while prefix < maxPrefix && o.character(at: prefix) == n.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        let maxSuffix = min(o.length, n.length) - prefix
        while suffix < maxSuffix
            && o.character(at: o.length - 1 - suffix) == n.character(at: n.length - 1 - suffix) {
            suffix += 1
        }
        // Widen rather than split a surrogate pair at either boundary.
        while prefix > 0 && UTF16.isLeadSurrogate(o.character(at: prefix - 1)) {
            prefix -= 1
        }
        while suffix > 0 && UTF16.isTrailSurrogate(o.character(at: o.length - suffix)) {
            suffix -= 1
        }

        let oldRange = NSRange(location: prefix, length: o.length - suffix - prefix)
        let replacement = n.substring(with: NSRange(location: prefix,
                                                    length: n.length - suffix - prefix))
        return (oldRange, replacement)
    }

    private func restoreSnapshot(_ snapshot: UndoSnapshot) {
        // Diff the current text against the snapshot: the changed span is what
        // this undo/redo actually touches, so it drives the selection and the
        // viewport — not the caret stored at snapshot time (which, for redo,
        // is wherever the caret happened to sit when undo was invoked).
        guard let diff = Self.textDiff(old: rawSource, new: snapshot.rawSource) else {
            // Nothing changed textually — just restore the caret.
            let clamped = min(snapshot.cursorInRaw, (rawSource as NSString).length)
            setSelectedRange(NSRange(location: clamped, length: 0))
            return
        }

        isUndoRedoing = true
        let oldIndentUnit = listIndentUnit
        let oldActive = activeBlockIndex
        let oldCount = blocks.count

        rawSource = snapshot.rawSource
        rebuildListIndentState()
        let (newBlocks, changed) = BlockParser.parseWithDiff(rawSource, previous: blocks)
        blocks = newBlocks

        var dirty = IndexSet(integersIn: changed)
        // Map the old active block through the diff (same scheme as the edit
        // path): prefix indices are unchanged, suffix indices shift by the
        // count delta, anything inside the window is already dirty.
        if let old = oldActive {
            let suffixCount = newBlocks.count - changed.upperBound
            if old < changed.lowerBound {
                dirty.insert(old)
            } else if old >= oldCount - suffixCount {
                dirty.insert(old + (newBlocks.count - oldCount))
            }
        }
        // listIndentUnit is document-global: when it changes, every list
        // block's rendered indentation changes with it.
        if listIndentUnit != oldIndentUnit {
            for (i, block) in blocks.enumerated() where block.kind == .listItem {
                dirty.insert(i)
            }
        }

        // The changed text in restored coordinates: select it so the user sees
        // exactly what this undo/redo did. A pure deletion has no new text to
        // select — the caret goes to the deletion point instead.
        let changedInNew = NSRange(location: diff.oldRange.location,
                                   length: (diff.replacement as NSString).length)
        let selection: NSRange? = changedInNew.length > 0 ? changedInNew : nil

        // Range-bounded storage replacement: layout outside the changed span
        // stays real. (The old full `recompose` reset the whole document to
        // TextKit 2 height estimates, and centering math done on estimates is
        // what made the post-undo scroll land too far down.)
        let apply = {
            self.recomposeReplacing(oldRange: diff.oldRange, with: diff.replacement,
                                    dirty: dirty, cursorInRaw: changedInNew.location,
                                    selectionInRaw: selection)
        }

        if typewriterModeEnabled {
            // Typewriter: always center on the changed text.
            apply()
            centerViewportOnCaret()
        } else if let scrollView = enclosingScrollView {
            // If any of the changed text is already on screen, hold the
            // viewport perfectly still; otherwise center the change.
            let savedOrigin = scrollView.contentView.bounds.origin
            apply()
            ensureCaretRegionLaidOut()
            if rangeIsVisible(changedInNew, forViewportOrigin: savedOrigin) {
                scrollView.contentView.scroll(to: savedOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            } else {
                centerViewportOnCaret()
            }
        } else {
            apply()
        }

        isUndoRedoing = false
        lastEditType = .other
        lastEditBlockIndex = nil
    }
}
