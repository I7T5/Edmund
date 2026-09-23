import AppKit

// MARK: - Custom Undo/Redo
//
// Custom undo stack operating on diffs, not snapshots. Completely bypasses
// NSTextView's built-in undo (allowsUndo = false) because recompose replaces
// the entire text storage, invalidating position-based undo.
//
// Each stack entry records a single contiguous edit: in the text state right
// after the edit, replacing `location ..< location + laterLength` with
// `earlierText` yields the pre-edit state. A coalesced typing run composes its
// keystrokes into one entry in place (see `compose`), so the stack's memory is
// bounded by the total edited span — never by document size × edit count.
// Undo applies an entry and pushes its inverse onto the redo stack; redo does
// the mirror image. Strict LIFO order guarantees every entry's coordinates
// still match the current text: undoing the newest entry restores exactly the
// state the next entry was recorded against.

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

    /// Push an undo entry if this edit starts a new coalescing group, else
    /// fold the edit into the group's open entry. Called from
    /// `shouldChangeText` before the edit applies. Usually `preEditText` is
    /// rawSource; after a drag deletion bypasses didChangeText, storage is the
    /// authoritative pre-edit text for the next mutation.
    func recordUndoIfNeeded(editRange: NSRange, replacement: String,
                            preEditText: String, forceNewGroup: Bool = false) {
        let editType = classifyEdit(range: editRange, replacement: replacement)

        let shouldPush = forceNewGroup || undoStack.isEmpty
            || editType == .other
            || editType != lastEditType
            || activeBlockIndex != lastEditBlockIndex

        if shouldPush {
            // The entry transforms the post-edit state back to the current
            // (pre-edit) text: the edit's replacement occupies
            // [location, location + replacement length) in the post-edit text,
            // and the text it removed from the pre-edit text is `earlierText`.
            let ns = preEditText as NSString
            let loc = min(editRange.location, ns.length)
            let len = min(editRange.length, ns.length - loc)
            undoStack.append(UndoEntry(
                location: loc,
                laterLength: (replacement as NSString).length,
                earlierText: ns.substring(with: NSRange(location: loc, length: len)),
                cursorInRaw: currentCursorInRaw()))
            redoStack.removeAll()
        } else {
            var entry = undoStack[undoStack.count - 1]
            compose(entry: &entry, editRange: editRange, replacement: replacement,
                    in: preEditText as NSString)
            undoStack[undoStack.count - 1] = entry
        }

        lastEditType = editType
        lastEditBlockIndex = activeBlockIndex
    }

    /// Marked text is provisional and its storage offsets no longer match
    /// rawSource. Capture one entry from the committed storage back to the
    /// pre-composition model, before didChangeText syncs that model.
    func recordDeferredMarkedTextUndoIfNeeded() {
        guard hasDeferredMarkedTextUndo, !hasMarkedText(),
              let committed = textStorage?.string else { return }
        hasDeferredMarkedTextUndo = false
        guard let diff = Self.textDiff(old: committed, new: rawSource) else { return }
        undoStack.append(UndoEntry(location: diff.oldRange.location,
                                   laterLength: diff.oldRange.length,
                                   earlierText: diff.replacement,
                                   cursorInRaw: currentCursorInRaw()))
        redoStack.removeAll()
        lastEditType = .other
        lastEditBlockIndex = nil
    }

    /// Widens the entry in place to also undo `editRange`/`replacement`, which
    /// transformed `c` (the current text) into the post-edit text. Invariant:
    /// replacing `[location, location + laterLength)` in the current text with
    /// `earlierText` yields the group's pre-edit text; the edit is expressed in
    /// `c`'s coordinates, so the splice pieces are read from `c`.
    func compose(entry: inout UndoEntry, editRange: NSRange,
                 replacement: String, in c: NSString) {
        let delta = (replacement as NSString).length - editRange.length
        let lo = min(entry.location, editRange.location)
        let hi = max(entry.location + entry.laterLength, editRange.upperBound)
        func splice(_ from: Int, _ to: Int) -> String {
            guard from < to, from < c.length else { return "" }
            return c.substring(with: NSRange(location: from,
                                             length: min(to, c.length) - from))
        }
        // The pre-edit text over [lo, hi): original characters outside the
        // span's [location, location + laterLength), spliced around the span's
        // own original text. Either splice piece is empty when the edit stays
        // inside the span or the span reaches the interval's edge.
        entry.earlierText = splice(lo, entry.location)
            + entry.earlierText
            + splice(entry.location + entry.laterLength, hi)
        entry.location = lo
        entry.laterLength = hi - lo + delta
    }

    /// Folds a secondary mutation of the same undo step — one made outside
    /// `shouldChangeText`, like list renumbering settling after a keystroke —
    /// into the stack-top entry, so undoing the step restores the pre-step
    /// text, not an intermediate state. `editRange`/`replacement` describe the
    /// mutation in `preEditText`, the text before it ran. No-op with an empty
    /// stack.
    func composeTopUndoEntry(editRange: NSRange, replacement: String,
                             in preEditText: NSString) {
        guard !undoStack.isEmpty else { return }
        var entry = undoStack[undoStack.count - 1]
        compose(entry: &entry, editRange: editRange, replacement: replacement,
                in: preEditText)
        undoStack[undoStack.count - 1] = entry
    }

    func performUndo() {
        guard let entry = undoStack.popLast() else { return }
        redoStack.append(inverse(of: entry))
        restoreEntry(entry)
    }

    func performRedo() {
        guard let entry = redoStack.popLast() else { return }
        undoStack.append(inverse(of: entry))
        restoreEntry(entry)
    }

    /// The entry that reverses `entry`, built against the current text: the
    /// text `entry` removes (its span's content) becomes the inverse's
    /// `earlierText`, and `entry`'s `earlierText` becomes the span the inverse
    /// removes from the restored text.
    private func inverse(of entry: UndoEntry) -> UndoEntry {
        let ns = rawSource as NSString
        precondition(entry.location >= 0 && entry.laterLength >= 0
                     && entry.location <= ns.length
                     && entry.laterLength <= ns.length - entry.location,
                     "Undo entry is outside the current text")
        return UndoEntry(
            location: entry.location,
            laterLength: (entry.earlierText as NSString).length,
            earlierText: ns.substring(with: NSRange(location: entry.location,
                                                    length: entry.laterLength)),
            cursorInRaw: currentCursorInRaw())
    }

    /// Rewrites the stack-top placeholder entry (pushed by a command before it
    /// mutated `rawSource`) as the diff from the mutated text back to
    /// `preEditText`. O(document) *time*, once per command — the memory win is
    /// what matters: the stack stores only the changed span.
    func finalizeTopUndoEntry(preEditText: String) {
        guard undoStack.count > 0,
              let diff = Self.textDiff(old: rawSource, new: preEditText)
        else { return }
        undoStack[undoStack.count - 1] = UndoEntry(
            location: diff.oldRange.location,
            laterLength: diff.oldRange.length,
            earlierText: diff.replacement,
            cursorInRaw: undoStack[undoStack.count - 1].cursorInRaw)
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

    private func restoreEntry(_ entry: UndoEntry) {
        // The entry's span is exactly what this undo/redo touches, so it drives
        // the selection and the viewport — not the caret stored at record time
        // (which, for redo, is wherever the caret happened to sit when undo was
        // invoked).
        let ns = rawSource as NSString
        precondition(entry.location >= 0 && entry.laterLength >= 0
                     && entry.location <= ns.length
                     && entry.laterLength <= ns.length - entry.location,
                     "Undo entry is outside the current text")
        let oldRange = NSRange(location: entry.location, length: entry.laterLength)
        let replacement = entry.earlierText

        guard ns.substring(with: oldRange) != replacement else {
            // Nothing changed textually — just restore the caret.
            setSelectedRange(NSRange(location: min(entry.cursorInRaw, ns.length), length: 0))
            return
        }

        isUndoRedoing = true
        let oldDepths = listDepths
        let oldActive = activeBlockIndex
        let oldCount = blocks.count

        rawSource = ns.replacingCharacters(in: oldRange, with: replacement)
        rebuildListIndentState()
        rebuildLinkDefState()
        let (newBlocks, changed) = BlockParser.parseWithDiff(rawSource, previous: blocks,
                                                             features: markdownFeatures)
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
        // Undoing an indent moves a list line back across a column boundary,
        // which re-depths the items nested below it too.
        dirty.formUnion(listDepthChanges(from: oldDepths))

        // The changed text in restored coordinates: select it so the user sees
        // exactly what this undo/redo did. A pure deletion has no new text to
        // select — the caret goes to the deletion point instead.
        let changedInNew = NSRange(location: oldRange.location,
                                   length: (replacement as NSString).length)
        let selection: NSRange? = changedInNew.length > 0 ? changedInNew : nil

        // Range-bounded storage replacement: layout outside the changed span
        // stays real. (The old full `recompose` reset the whole document to
        // TextKit 2 height estimates, and centering math done on estimates is
        // what made the post-undo scroll land too far down.)
        let apply = {
            self.recomposeReplacing(oldRange: oldRange, with: replacement,
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
