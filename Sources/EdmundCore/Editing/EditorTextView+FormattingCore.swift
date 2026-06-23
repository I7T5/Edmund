import AppKit

// MARK: - Formatting primitives & helpers
//
// The Format-menu commands (EditorTextView+FormattingCommands) all funnel
// through the two edit primitives here. They follow the same template as the
// Tab-indent path (EditorTextView+Indentation): push a single undo snapshot,
// rebuild `rawSource`, re-parse blocks, and restyle only the affected span via
// `recomposeReplacing` — preserving the hard invariant that the text storage
// always equals `rawSource` (rendering is attribute-only).

extension EditorTextView {

    // MARK: - Edit primitives

    /// Replace one contiguous `rawRange` (in current rawSource coordinates) with
    /// `replacement` as a single undoable step, restyle the affected block span
    /// in place, and set `select` (a caret when `length == 0`).
    func applyFormattingEdit(rawRange: NSRange, replacement: String, select: NSRange) {
        guard !blocks.isEmpty else { return }
        let ns = rawSource as NSString
        let loc = min(max(0, rawRange.location), ns.length)
        let clamped = NSRange(location: loc, length: min(rawRange.length, ns.length - loc))

        guard let startBlock = blockIndexForRawOffset(clamped.location),
              let endBlock = blockIndexForRawOffset(clamped.upperBound) else { return }

        // Pre-edit storage span covering exactly the affected blocks, so layout
        // (and the viewport) above/below the edit stays put.
        let oldSpan = NSRange(
            location: blocks[startBlock].range.location,
            length: blocks[endBlock].range.upperBound - blocks[startBlock].range.location)

        undoStack.append(UndoSnapshot(rawSource: rawSource, cursorInRaw: selectedRange().location))
        redoStack.removeAll()
        lastEditType = .other
        lastEditBlockIndex = nil

        rawSource = ns.replacingCharacters(in: clamped, with: replacement)
        rebuildListIndentState()
        blocks = BlockParser.parse(rawSource, previous: blocks)

        // The replaced region grew/shrank by `delta`; the new block-aligned span
        // is the old span plus that delta. Its text is the storage replacement.
        let delta = (replacement as NSString).length - clamped.length
        let newSpan = NSRange(location: oldSpan.location, length: max(0, oldSpan.length + delta))
        let newRaw = rawSource as NSString
        let safeSpan = NSRange(location: min(newSpan.location, newRaw.length),
                               length: min(newSpan.length, newRaw.length - min(newSpan.location, newRaw.length)))
        let newText = newRaw.substring(with: safeSpan)

        let lastPos = safeSpan.length > 0 ? safeSpan.upperBound - 1 : safeSpan.location
        let newStart = blockIndexForRawOffset(safeSpan.location) ?? 0
        let newEnd = blockIndexForRawOffset(lastPos) ?? newStart
        let dirty = IndexSet(integersIn: newStart...min(newEnd, blocks.count - 1))

        let sel = NSRange(location: min(select.location, newRaw.length),
                          length: min(select.length, newRaw.length - min(select.location, newRaw.length)))
        stabilizingViewport {
            recomposeReplacing(oldRange: oldSpan, with: newText, dirty: dirty,
                               cursorInRaw: sel.location,
                               selectionInRaw: sel.length > 0 ? sel : nil)
        }
        document?.updateChangeCount(.changeDone)
    }

    /// Replace the whole document as one undoable step (for non-contiguous edits
    /// like footnotes: an inline marker plus an end-of-file definition).
    func applyWholeDocumentEdit(newRawSource: String, select: NSRange) {
        undoStack.append(UndoSnapshot(rawSource: rawSource, cursorInRaw: selectedRange().location))
        redoStack.removeAll()
        lastEditType = .other
        lastEditBlockIndex = nil

        rawSource = newRawSource
        rebuildListIndentState()
        blocks = BlockParser.parse(rawSource, previous: blocks)

        let len = (rawSource as NSString).length
        let loc = min(select.location, len)
        let sel = NSRange(location: loc, length: min(select.length, len - loc))
        recompose(cursorInRaw: sel.location, selectionInRaw: sel.length > 0 ? sel : nil)
        document?.updateChangeCount(.changeDone)
    }

    // MARK: - Line-range helpers

    /// The full lines covered by the current selection (or caret), their
    /// contents split on `\n`, and whether the range ends in a trailing newline.
    func selectedLineContext() -> (range: NSRange, lines: [String], trailingNewline: Bool) {
        let ns = rawSource as NSString
        let sel = selectedRange()
        let startLine = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        let lastChar = sel.length > 0 ? max(sel.location, sel.upperBound - 1) : sel.location
        let endLine = ns.lineRange(for: NSRange(location: min(lastChar, ns.length), length: 0))
        let range = NSRange(location: startLine.location,
                            length: endLine.upperBound - startLine.location)
        let text = ns.substring(with: range)
        let trailing = text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        if trailing { lines.removeLast() }
        return (range, lines, trailing)
    }

    /// Apply a per-line `transform` over the selected line range. With a
    /// selection the transformed lines stay selected; with a bare caret the
    /// caret tracks its line (shifted by that line's length change).
    func transformSelectedLines(_ transform: ([String]) -> [String]) {
        let sel = selectedRange()
        let ctx = selectedLineContext()
        let newLines = transform(ctx.lines)
        var replacement = newLines.joined(separator: "\n")
        if ctx.trailingNewline { replacement += "\n" }

        let select: NSRange
        if sel.length > 0 {
            let len = (replacement as NSString).length - (ctx.trailingNewline ? 1 : 0)
            select = NSRange(location: ctx.range.location, length: max(0, len))
        } else {
            let oldFirst = (ctx.lines.first.map { ($0 as NSString).length }) ?? 0
            let newFirst = (newLines.first.map { ($0 as NSString).length }) ?? 0
            let caretInLine = sel.location - ctx.range.location
            let newCaretInLine = min(max(0, caretInLine + (newFirst - oldFirst)), newFirst)
            select = NSRange(location: ctx.range.location + newCaretInLine, length: 0)
        }
        applyFormattingEdit(rawRange: ctx.range, replacement: replacement, select: select)
    }

    // MARK: - Inline wrap (toggle)

    /// Wrap the selection (or caret) in `open`…`close`, or unwrap when already
    /// wrapped. Span-aware per the spec:
    ///   - With a selection: toggle off only when the delimiters sit immediately
    ///     around the selection (or the selection itself is the wrapped text).
    ///   - With a caret: remove empty delimiters straddling the caret, else
    ///     unwrap the current word if it is wrapped, else insert empty
    ///     delimiters with the caret centered.
    func toggleInlineWrap(open: String, close: String) {
        let ns = rawSource as NSString
        let sel = selectedRange()
        let openLen = (open as NSString).length
        let closeLen = (close as NSString).length

        if sel.length > 0 {
            // Delimiters immediately surround the selection.
            let before = sel.location - openLen
            if before >= 0, sel.upperBound + closeLen <= ns.length,
               ns.substring(with: NSRange(location: before, length: openLen)) == open,
               ns.substring(with: NSRange(location: sel.upperBound, length: closeLen)) == close {
                let inner = ns.substring(with: sel)
                let full = NSRange(location: before, length: openLen + sel.length + closeLen)
                applyFormattingEdit(rawRange: full, replacement: inner,
                                    select: NSRange(location: before, length: sel.length))
                return
            }
            // The selection itself is the wrapped text.
            let selText = ns.substring(with: sel)
            if (selText as NSString).length >= openLen + closeLen,
               selText.hasPrefix(open), selText.hasSuffix(close) {
                let innerLen = (selText as NSString).length - openLen - closeLen
                let inner = (selText as NSString).substring(with: NSRange(location: openLen, length: innerLen))
                applyFormattingEdit(rawRange: sel, replacement: inner,
                                    select: NSRange(location: sel.location, length: innerLen))
                return
            }
            // Wrap on.
            applyFormattingEdit(rawRange: sel, replacement: open + selText + close,
                                select: NSRange(location: sel.location + openLen, length: sel.length))
            return
        }

        let caret = sel.location
        // Empty delimiters straddling the caret → remove.
        if caret - openLen >= 0, caret + closeLen <= ns.length,
           ns.substring(with: NSRange(location: caret - openLen, length: openLen)) == open,
           ns.substring(with: NSRange(location: caret, length: closeLen)) == close {
            applyFormattingEdit(rawRange: NSRange(location: caret - openLen, length: openLen + closeLen),
                                replacement: "",
                                select: NSRange(location: caret - openLen, length: 0))
            return
        }
        // Current word already wrapped → unwrap.
        if let word = currentWordRange() {
            let before = word.location - openLen
            if before >= 0, word.upperBound + closeLen <= ns.length,
               ns.substring(with: NSRange(location: before, length: openLen)) == open,
               ns.substring(with: NSRange(location: word.upperBound, length: closeLen)) == close {
                let inner = ns.substring(with: word)
                let full = NSRange(location: before, length: openLen + word.length + closeLen)
                applyFormattingEdit(rawRange: full, replacement: inner,
                                    select: NSRange(location: caret - openLen, length: 0))
                return
            }
        }
        // Insert empty delimiters, caret centered.
        applyFormattingEdit(rawRange: NSRange(location: caret, length: 0),
                            replacement: open + close,
                            select: NSRange(location: caret + openLen, length: 0))
    }

    /// The maximal run of alphanumerics around the caret, or nil when the caret
    /// is not adjacent to a word character.
    func currentWordRange() -> NSRange? {
        let ns = rawSource as NSString
        let caret = selectedRange().location
        func isWord(_ at: Int) -> Bool {
            guard let scalar = ns.substring(with: NSRange(location: at, length: 1)).unicodeScalars.first
            else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        var start = caret
        while start > 0, isWord(start - 1) { start -= 1 }
        var end = caret
        while end < ns.length, isWord(end) { end += 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    // MARK: - Markdown line helpers

    /// Number of leading `#` (1–6) when the line is an ATX heading (`#`s then a
    /// space); 0 otherwise.
    func leadingHashCount(_ line: String) -> Int {
        let ns = line as NSString
        var i = 0
        while i < ns.length, i < 6, ns.character(at: i) == 0x23 { i += 1 }  // '#'
        if i > 0, i < ns.length, ns.character(at: i) == 0x20 { return i }
        return 0
    }

    func stripLeadingHashes(_ line: String) -> String {
        let n = leadingHashCount(line)
        guard n > 0 else { return line }
        let ns = line as NSString
        var j = n
        while j < ns.length, ns.character(at: j) == 0x20 { j += 1 }
        return ns.substring(from: j)
    }

    /// The leading list number when the line is `N. `; nil otherwise.
    func leadingListNumber(_ line: String) -> Int? {
        let ns = line as NSString
        var i = 0
        while i < ns.length, ns.character(at: i) >= 0x30, ns.character(at: i) <= 0x39 { i += 1 }
        guard i > 0, i + 1 < ns.length,
              ns.character(at: i) == 0x2E, ns.character(at: i + 1) == 0x20 else { return nil }
        return Int(ns.substring(to: i))
    }

    func stripLeadingNumber(_ line: String) -> String {
        guard leadingListNumber(line) != nil else { return line }
        let ns = line as NSString
        var i = 0
        while ns.character(at: i) != 0x2E { i += 1 }
        return ns.substring(from: i + 2)  // skip ". "
    }

    /// The next unused footnote number (max existing `[^n]` + 1, starting at 1).
    func nextFootnoteNumber() -> Int {
        guard let re = try? NSRegularExpression(pattern: #"\[\^(\d+)\]"#) else { return 1 }
        let ns = rawSource as NSString
        var maxN = 0
        re.enumerateMatches(in: rawSource, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges > 1, let n = Int(ns.substring(with: m.range(at: 1))) else { return }
            maxN = max(maxN, n)
        }
        return maxN + 1
    }

    /// Returns the link text when `s` is exactly `[text](dest)`, else nil.
    func unwrapLink(_ s: String) -> String? {
        captureFirst(s, pattern: #"^\[([^\]]*)\]\([^)]*\)$"#)
    }

    /// Returns the alt text when `s` is exactly `![alt](dest)`, else nil.
    func unwrapImage(_ s: String) -> String? {
        captureFirst(s, pattern: #"^!\[([^\]]*)\]\([^)]*\)$"#)
    }

    private func captureFirst(_ s: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}
