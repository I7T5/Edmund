import AppKit

/// The edit pipeline: how keystrokes flow from NSTextView into `rawSource`,
/// reparse, and an attribute-only restyle of exactly the affected blocks.
extension EditorTextView {

    /// NSTextView copies the attributes next to the caret into `typingAttributes`.
    /// When the caret sits beside a hidden delimiter (our near-zero-size
    /// `hiddenFont` + clear color), newly inserted text inherits that invisible
    /// font. Regular typing self-heals via `applyBlockStyle` on each keystroke,
    /// but IME composition (e.g. Pinyin) is deferred while marked — so the
    /// composing text would render invisibly and input appears broken. Refuse the
    /// invisible font here so composition is always visible; the block restyle
    /// still applies the correct final styling on commit.
    public override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set {
            var attrs = newValue
            if let font = attrs[.font] as? NSFont, font.pointSize < 1.0 {
                attrs[.font] = bodyFont
                if (attrs[.foregroundColor] as? NSColor) == .clear {
                    attrs[.foregroundColor] = foregroundColor
                }
            }
            super.typingAttributes = attrs
        }
    }

    public override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if isUpdating {
            traceEdit("shouldChangeText REJECTED (isUpdating) range=\(affectedCharRange) repl=\(logSnippet(replacementString))")
            return false
        }
        if let replacement = replacementString {
            if !isUndoRedoing {
                recordUndoIfNeeded(editRange: affectedCharRange, replacement: replacement)
            }
        }
        traceEdit("shouldChangeText OK range=\(affectedCharRange) repl=\(logSnippet(replacementString))")
        scheduleBypassedEditSyncCheck()
        return true
    }

    /// AppKit does not pair every storage mutation with `didChangeText()`.
    /// Known case: after a drag of the selected text whose drop falls through
    /// to no valid target (e.g. released past the end of the document), the
    /// drag-move's source deletion runs shouldChangeText → replaceCharacters
    /// and never calls didChangeText. rawSource/blocks then silently freeze:
    /// every later edit does its offset math against the stale model (the
    /// issue-#156 caret leap) and autosave writes the stale rawSource.
    /// didChangeText consumes the storage's pendingEdit synchronously within
    /// the same event turn, so a pendingEdit still unconsumed on the next
    /// run-loop pass is exactly the "didChangeText was bypassed" signal —
    /// heal by running the sync it would have run.
    private func scheduleBypassedEditSyncCheck() {
        guard !bypassedEditCheckScheduled else { return }
        bypassedEditCheckScheduled = true
        // RunLoop.perform, not DispatchQueue.main.async: identical "next
        // run-loop pass" timing in the app, but also drainable by
        // `RunLoop.main.run(until:)` in tests.
        RunLoop.main.perform { [weak self] in
            // The main run loop only ever performs on the main thread; the
            // closure just isn't statically annotated as such.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bypassedEditCheckScheduled = false
                guard let storage = self.textStorage as? EditorTextStorage,
                      storage.pendingEdit != nil,
                      !self.isUpdating, !self.isUndoRedoing,
                      // During IME composition the unconsumed pendingEdit is
                      // legitimate — didChangeText defers the sync until commit.
                      !self.hasMarkedText() else { return }
                // Permanent breadcrumb (release builds too): if a desync recurs,
                // grep ~/.edmund/logs for this line to see which path bypassed
                // didChangeText.
                Log.info("healing storage edit that bypassed didChangeText: " +
                         "storLen=\(storage.length) rawLen=\((self.rawSource as NSString).length)",
                         category: .edit)
                self.syncRawSourceFromDisplay()
                self.document?.updateChangeCount(.changeDone)
            }
        }
    }

    public override func didChangeText() {
        super.didChangeText()
        guard !isUpdating, !isUndoRedoing else {
            traceEdit("didChangeText SKIPPED sync (isUpdating=\(isUpdating) isUndoRedoing=\(isUndoRedoing))")
            return
        }
        // While an input method is composing (marked text — e.g. emoji search,
        // accent/IME entry), the storage holds provisional text. Re-styling it
        // (setAttributes over the marked range) interferes with the composition
        // and can abort it, so defer all syncing/restyling until the IME commits
        // — which fires didChangeText again with no marked text.
        guard !hasMarkedText() else {
            traceEdit("didChangeText DEFERRED sync (marked text active)")
            return
        }
        syncRawSourceFromDisplay()
        document?.updateChangeCount(.changeDone)
        scrollCursorToCenter()
    }

    /// Syncs rawSource from the text storage, re-parses blocks, and restyles
    /// exactly the blocks the edit affected: the parser's changed window, the
    /// old and new active blocks, and — when the document-global list indent
    /// unit moved — every list block. One flush, attribute-only; the storage
    /// string is never replaced on the edit path.
    private func syncRawSourceFromDisplay() {
        guard let ts = textStorage else { return }

        let oldIndentUnit = listIndentUnit
        rawSource = ts.string
        let sel = selectedRange()
        let cursorRaw = min(sel.location, (rawSource as NSString).length)

        let oldCount = blocks.count
        let oldActive = activeBlockIndex
        // Incremental parse from the storage's accumulated edit — O(edit);
        // full positional-diff parse as the fallback.
        let newBlocks: [Block]
        let changed: Range<Int>
        if let pending = (ts as? EditorTextStorage)?.consumePendingEdit(),
           let incremental = BlockParser.incrementalParse(text: rawSource,
                                                          old: blocks,
                                                          editedOldRange: pending.oldRange,
                                                          delta: pending.delta) {
            (newBlocks, changed) = incremental
            #if DEBUG
            verifyIncrementalParse(newBlocks)
            #endif
            // Update the indent histogram from exactly the replaced blocks
            // (old) and their replacements (new) — O(edit), same effect as a
            // whole-document rescan.
            let suffixCount = newBlocks.count - changed.upperBound
            for i in changed.lowerBound ..< (oldCount - suffixCount) {
                listIndentState.remove(blocks[i].content)
            }
            for i in changed {
                listIndentState.add(newBlocks[i].content)
            }
            listIndentUnit = listIndentState.unit
        } else {
            (newBlocks, changed) = BlockParser.parseWithDiff(rawSource, previous: blocks)
            rebuildListIndentState()
        }
        blocks = newBlocks

        var dirty = IndexSet(integersIn: changed)

        // Map the old active block through the diff so its deactivation
        // restyle lands on the right index: prefix indices are unchanged,
        // suffix indices shift by the count delta, and anything inside the
        // window is already dirty.
        if let old = oldActive {
            let suffixCount = newBlocks.count - changed.upperBound
            if old < changed.lowerBound {
                dirty.insert(old)
            } else if old >= oldCount - suffixCount {
                dirty.insert(old + (newBlocks.count - oldCount))
            }
        }

        // The block under the cursor gets cursor-aware delimiter styling
        // (this also subsumes the old per-keystroke applyBlockStyle pass).
        if let newActive = blockIndexForRawOffset(cursorRaw) {
            dirty.insert(newActive)
        }

        // listIndentUnit is document-global: when it changes, the rendered
        // indentation of every list block changes with it.
        if listIndentUnit != oldIndentUnit {
            for (i, block) in blocks.enumerated() where block.kind == .listItem {
                dirty.insert(i)
            }
        }

        recomposeDirty(dirty, cursorInRaw: cursorRaw)
        traceEdit("synced cursorRaw=\(cursorRaw) changed=\(changed.lowerBound)..<\(changed.upperBound) oldActive=\(oldActive.map(String.init) ?? "nil")")
        verifyEditorInvariants("syncRawSourceFromDisplay")
    }

    #if DEBUG
    /// Debug oracle for the incremental parser: every incremental result must
    /// equal a from-scratch parse (content, ranges, kinds — IDs are allowed
    /// to differ). Skipped under MD_PERF so measurements stay representative.
    private func verifyIncrementalParse(_ incremental: [Block]) {
        guard ProcessInfo.processInfo.environment["MD_PERF"] == nil else { return }
        let reference = BlockParser.parse(rawSource)
        guard incremental.count == reference.count else {
            assertionFailure("""
            incremental parse diverged: \(incremental.count) blocks \
            vs \(reference.count) reference
            """)
            return
        }
        for (a, b) in zip(incremental, reference) {
            if a.content != b.content || a.range != b.range || a.kind != b.kind {
                assertionFailure("""
                incremental parse diverged at \(a.range): \
                \(String(reflecting: a.content)) [\(a.kind)] vs \
                \(String(reflecting: b.content)) [\(b.kind)] at \(b.range)
                """)
                return
            }
        }
    }
    #endif
}
