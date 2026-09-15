// Edit ▸ Hard Wrap Paragraphs — reflow paragraphs to 80 columns on demand.
//
// The automatic side of hard wrap lives at the document's edges (unwrap on
// open, re-wrap on save); this is the manual escape hatch for wrapping a file
// that didn't arrive wrapped, or re-flowing a paragraph mid-session.
//
// It rebuilds `rawSource` and goes through `recomposeReplacing` rather than
// `insertText`, because it rewrites a whole span at once — the same route
// Tab/Shift-Tab indentation takes, with the same caller obligations (undo
// snapshot, re-parse, viewport stabilization).

import AppKit

extension EditorTextView {

    /// Reflows the paragraphs the selection touches, or the whole document when
    /// nothing is selected.
    @objc public func hardWrapParagraphs(_ sender: Any?) {
        let sel = selectedRange()
        guard let (startBlock, endBlock) = paragraphRunRange(for: sel) else { return }

        let oldRange = NSRange(
            location: blocks[startBlock].range.location,
            length: blocks[endBlock].range.upperBound - blocks[startBlock].range.location)
        let ns = rawSource as NSString
        let oldText = ns.substring(with: oldRange)
        let newText = HardWrap.wrap(oldText, features: markdownFeatures,
                                    column: hardWrapColumn)
        // Already wrapped: leave the document — and the undo stack — alone.
        guard newText != oldText else { return }

        // Record undo
        undoStack.append(UndoSnapshot(rawSource: rawSource, cursorInRaw: sel.location))
        redoStack.removeAll()
        lastEditType = .other
        lastEditBlockIndex = nil

        rawSource = ns.replacingCharacters(in: oldRange, with: newText)
        rebuildListIndentState()
        rebuildLinkDefState()
        blocks = BlockParser.parse(rawSource, previous: blocks, features: markdownFeatures)

        // Reflow only moves whitespace, so the caret's offset into the span is
        // very nearly where it was; clamp it to the span's new length. A caret
        // before the span doesn't move at all.
        let newSpan = NSRange(location: oldRange.location,
                              length: (newText as NSString).length)
        let cursor: Int
        if sel.location <= oldRange.location {
            cursor = sel.location
        } else {
            cursor = newSpan.location
                + min(sel.location - oldRange.location, newSpan.length)
        }
        // You selected paragraphs and they are still the same paragraphs, so
        // keep them selected rather than collapsing to a caret.
        let selectionInRaw = sel.length > 0 ? newSpan : nil

        stabilizingViewport {
            recomposeReplacing(oldRange: oldRange, with: newText,
                               dirty: dirtySet(covering: newSpan),
                               cursorInRaw: selectionInRaw?.location ?? cursor,
                               selectionInRaw: selectionInRaw)
        }
        // No `renumberOrderedListRunsIfNeeded`: only `.paragraph` blocks are
        // rewritten, and the fill refuses to break in front of a list marker,
        // so no ordered-list run can gain, lose or re-depth a member here.

        // Deliberately does not set `wasHardWrapped`. That flag exists to record
        // what the *file* was when it opened; a command that only edits the
        // buffer has no business claiming it. Setting it here would also make
        // undo look broken — the text would revert but the next save would wrap
        // it straight back. The wrapped buffer is written out verbatim, and on
        // the next open the join detects the wrapping for itself.
        document?.updateChangeCount(.changeDone)
    }

    /// The inclusive block range to reflow: the blocks `sel` touches, widened to
    /// whole runs of consecutive paragraphs. Widening matters because
    /// `HardWrap` treats the text it is given as complete paragraphs — handing
    /// it half a run would fill that half as if the rest weren't there.
    /// Returns nil when there is no paragraph in reach.
    private func paragraphRunRange(for sel: NSRange) -> (Int, Int)? {
        guard !blocks.isEmpty else { return nil }

        var startIdx = 0
        var endIdx = blocks.count - 1
        // Nothing selected means the whole document.
        if sel.length > 0 {
            guard let s = blockIndexForRawOffset(sel.location),
                  var e = blockIndexForRawOffset(sel.location + sel.length)
            else { return nil }
            // A selection ending exactly on a block's first character doesn't
            // meaningfully cover that block (the same rule indentation uses).
            if e > s && e < blocks.count
                && sel.location + sel.length == blocks[e].range.location { e -= 1 }
            startIdx = s
            endIdx = e
        }

        guard blocks[startIdx...endIdx].contains(where: { $0.kind == .paragraph })
        else { return nil }

        while startIdx > 0, blocks[startIdx].kind == .paragraph,
              blocks[startIdx - 1].kind == .paragraph { startIdx -= 1 }
        while endIdx < blocks.count - 1, blocks[endIdx].kind == .paragraph,
              blocks[endIdx + 1].kind == .paragraph { endIdx += 1 }
        return (startIdx, endIdx)
    }

    /// Every block overlapping the rewritten span, so the recompose restyles
    /// exactly what changed and leaves the rest of the document's styling —
    /// and its layout — alone.
    private func dirtySet(covering span: NSRange) -> IndexSet {
        var dirty = IndexSet()
        for (i, block) in blocks.enumerated()
        where NSIntersectionRange(block.range, span).length > 0
            || block.range.location == span.location {
            dirty.insert(i)
        }
        return dirty
    }
}
