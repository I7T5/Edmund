import AppKit

/// Caret-movement handling: when the caret crosses into a different block we
/// restyle the old and new active blocks (revealing/hiding their raw markdown);
/// within a block we just update which token's delimiters are shown.
extension EditorTextView {

    @objc func selectionDidChange(_ notification: Notification) {
        traceEdit("selectionDidChange")
        // A selection change landing mid-recompose is the drift signature
        // (issue #156); the stack names the AppKit path that moved the caret.
        if isUpdating { traceSelectionOrigin() }
        guard !isUpdating else { return }
        // NSTextView moves the selection DURING an edit, before didChangeText
        // runs the sync — at that moment `blocks` still has pre-edit ranges.
        // Styling here would apply stale ranges/content against the new text,
        // spilling wrong attributes across block boundaries. The pending edit
        // is exactly the "storage ahead of blocks" signal; didChangeText's
        // flush styles the active block anyway.
        if let storage = textStorage as? EditorTextStorage,
           storage.pendingEdit != nil { return }
        // Don't restyle while an input method is composing (see didChangeText).
        guard !hasMarkedText() else { return }

        let sel = selectedRange()
        let rawOffset = sel.location
        let newActiveIndex = blockIndexForRawOffset(rawOffset)

        if newActiveIndex != activeBlockIndex && !pendingRecompose {
            pendingRecompose = true
            // Capture the flag now — it's reset synchronously after mouseDown
            // returns, before this async block runs.
            let fromMouse = suppressTypewriterCentering
            DispatchQueue.main.async { [weak self, fromMouse] in
                guard let self = self else { return }
                // Always clear the flag first. If we bail out below (a recompose is
                // mid-flight and will set the active block itself), leaving it set
                // would permanently wedge active-block switching — the cursor could
                // never re-activate a block, so e.g. a callout would stay rendered
                // with un-editable zero-width marker characters.
                self.pendingRecompose = false
                guard !self.isUpdating else { return }
                // Never restyle (mutate storage / invalidate layout) while an
                // input method is composing. This async block was scheduled
                // before composition began, so — unlike the synchronous guard
                // above — `hasMarkedText()` can have flipped true in between.
                // Running `recomposeDirty` over storage that holds a live
                // composition can strand the marked text in the input context,
                // after which `didChangeText` keeps bailing on its own
                // marked-text guard and the storage/`rawSource` invariant breaks
                // — the "delete drift" bug. The active-block restyle is applied
                // anyway when composition commits (didChangeText → recomposeDirty).
                guard !self.hasMarkedText() else { return }

                // Restyle the new active block now. DEFER the old active block
                // if it's off screen: deactivating it (rendered ↔ raw — callout
                // box, checklist marker, …) changes its height, and doing that
                // synchronously while the user is looking elsewhere shifts the
                // whole viewport. Marking it unstyled hands it to the async
                // drain, which TextKit 2 lays out without disturbing the
                // viewport. Don't re-set the selection (that triggers AppKit's
                // autoscroll-to-selection on stale layout).
                let loc = self.selectedRange().location
                let newIdx = self.blockIndexForRawOffset(loc)
                var dirty = IndexSet()
                if let n = newIdx { dirty.insert(n) }
                var deferred = false
                if let old = self.activeBlockIndex, old != newIdx, old < self.blocks.count {
                    if let vis = self.syncStylingBlockRange(), vis.contains(old) {
                        dirty.insert(old)   // visible — restyle in place
                    } else {
                        self.blocks[old].isStyled = false   // off screen — defer
                        deferred = true
                    }
                }
                // Only the new (visible) active block changes height now, so the
                // caret anchor's delta is small and reliable. Typewriter mode
                // centers on the post-restyle layout instead.
                if self.typewriterModeEnabled && !fromMouse {
                    self.recomposeDirty(dirty, cursorInRaw: loc)
                    self.scrollCursorToCenter()
                } else {
                    self.preservingViewportAnchor {
                        self.recomposeDirty(dirty, cursorInRaw: loc)
                    }
                }
                if deferred { self.scheduleProgressiveStyling() }
            }
            return
        } else if newActiveIndex == activeBlockIndex {
            // Same block — update active token (re-style to show/hide delimiters)
            applyBlockStyle()
        }
        if !suppressTypewriterCentering { scrollCursorToCenter() }
    }
}
