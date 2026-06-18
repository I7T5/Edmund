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
        recompose(cursorInRaw: snapshot.cursorInRaw)
        isUndoRedoing = false
        lastEditType = .other
        lastEditBlockIndex = nil
    }
}
