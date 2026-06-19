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

    private func restoreSnapshot(_ snapshot: UndoSnapshot) {
        isUndoRedoing = true
        rawSource = snapshot.rawSource
        rebuildListIndentState()
        blocks = BlockParser.parse(rawSource, previous: blocks)

        // Drive the viewport deliberately so undo/redo doesn't lurch.
        if typewriterModeEnabled {
            // Typewriter: the caret is always centered, so re-center on it.
            recompose(cursorInRaw: snapshot.cursorInRaw)
            centerViewportOnCaret()
        } else if let scrollView = enclosingScrollView {
            // Remember exactly where the viewport was, recompose, then: if the
            // restored caret (the change being undone) is already on screen,
            // hold the viewport perfectly still — no measured-delta nudge, so no
            // residual jump. Only when the edit is off-screen do we scroll, and
            // then we put the caret at the exact vertical center.
            let savedOrigin = scrollView.contentView.bounds.origin
            recompose(cursorInRaw: snapshot.cursorInRaw)
            // Lay out the caret's real geometry before deciding visible-vs-center,
            // otherwise an off-screen caret's estimated position can look "visible"
            // and the viewport wrongly holds instead of centering.
            ensureCaretRegionLaidOut()
            if caretIsVisible(forViewportOrigin: savedOrigin) {
                scrollView.contentView.scroll(to: savedOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            } else {
                centerViewportOnCaret()
            }
        } else {
            recompose(cursorInRaw: snapshot.cursorInRaw)
        }

        isUndoRedoing = false
        lastEditType = .other
        lastEditBlockIndex = nil
    }
}
