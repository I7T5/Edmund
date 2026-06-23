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
    /// wrapped. Span-aware:
    ///   - With a selection: strips leading/trailing spaces before wrapping, so
    ///     `" word "` → `" **word** "`. Toggle-off checks the trimmed range.
    ///   - With a caret: removes empty delimiters straddling the caret; else
    ///     unwraps the current word when it is already wrapped; else inserts
    ///     empty delimiters (or, when `expandToWord` is true, wraps the current
    ///     word instead of inserting empty delimiters).
    func toggleInlineWrap(open: String, close: String, expandToWord: Bool = false) {
        let ns = rawSource as NSString
        let sel = selectedRange()
        let openLen = (open as NSString).length
        let closeLen = (close as NSString).length

        if sel.length > 0 {
            let selText = ns.substring(with: sel)

            // Compute effective leading/trailing whitespace to strip.
            let leading = selText.prefix(while: { $0 == " " || $0 == "\t" }).count
            let trailing = selText.reversed().prefix(while: { $0 == " " || $0 == "\t" }).count
            let hasContent = leading + trailing < sel.length
            let effLead = hasContent ? leading : 0
            let effTrail = hasContent ? trailing : 0
            let trimmedSel = NSRange(location: sel.location + effLead,
                                     length: sel.length - effLead - effTrail)
            let trimmedText = ns.substring(with: trimmedSel)

            // Check 1: delimiters sit immediately around the trimmed selection and are
            // not part of a longer run of the same character (e.g. `*` inside `**`).
            let before = trimmedSel.location - openLen
            if before >= 0, trimmedSel.upperBound + closeLen <= ns.length,
               ns.substring(with: NSRange(location: before, length: openLen)) == open,
               ns.substring(with: NSRange(location: trimmedSel.upperBound, length: closeLen)) == close,
               delimiterIsIsolated(open: open, close: close,
                                   openAt: before, closeAt: trimmedSel.upperBound, in: ns) {
                let full = NSRange(location: before, length: openLen + trimmedSel.length + closeLen)
                applyFormattingEdit(rawRange: full, replacement: trimmedText,
                                    select: NSRange(location: before, length: trimmedSel.length))
                return
            }

            // Check 2: the trimmed selection itself is the wrapped text.
            let trimmedLen = (trimmedText as NSString).length
            if trimmedLen >= openLen + closeLen,
               trimmedText.hasPrefix(open), trimmedText.hasSuffix(close) {
                let innerLen = trimmedLen - openLen - closeLen
                let inner = (trimmedText as NSString).substring(with: NSRange(location: openLen, length: innerLen))
                applyFormattingEdit(rawRange: trimmedSel, replacement: inner,
                                    select: NSRange(location: trimmedSel.location, length: innerLen))
                return
            }

            // Wrap on — apply only to the non-whitespace content.
            let leadStr = String(selText.prefix(effLead))
            let trailStr = String(selText.suffix(effTrail))
            let replacement = leadStr + open + trimmedText + close + trailStr
            applyFormattingEdit(rawRange: sel, replacement: replacement,
                                select: NSRange(location: sel.location + effLead + openLen,
                                                length: trimmedSel.length))
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
        // Current word already wrapped → unwrap (only when the delimiter is isolated,
        // i.e. not embedded inside a longer run such as `*` inside `**`).
        if let word = currentWordRange() {
            let before = word.location - openLen
            if before >= 0, word.upperBound + closeLen <= ns.length,
               ns.substring(with: NSRange(location: before, length: openLen)) == open,
               ns.substring(with: NSRange(location: word.upperBound, length: closeLen)) == close,
               delimiterIsIsolated(open: open, close: close,
                                   openAt: before, closeAt: word.upperBound, in: ns) {
                let inner = ns.substring(with: word)
                let full = NSRange(location: before, length: openLen + word.length + closeLen)
                applyFormattingEdit(rawRange: full, replacement: inner,
                                    select: NSRange(location: caret - openLen, length: 0))
                return
            }
            // Expand to word when requested.
            if expandToWord {
                let wordText = ns.substring(with: word)
                let replacement = open + wordText + close
                applyFormattingEdit(rawRange: word, replacement: replacement,
                                    select: NSRange(location: word.location + openLen
                                                        + (wordText as NSString).length, length: 0))
                return
            }
        }
        // Insert empty delimiters, caret centered.
        applyFormattingEdit(rawRange: NSRange(location: caret, length: 0),
                            replacement: open + close,
                            select: NSRange(location: caret + openLen, length: 0))
    }

    /// Returns false when the delimiter found at `openAt`/`closeAt` is embedded in a
    /// longer run of the same character — e.g. a lone `*` at position 1 of `**word**`
    /// is not an isolated italic delimiter; it is the inner character of the bold `**`.
    ///
    /// Rule: the character immediately before the opening delimiter must not equal the
    /// opening's first character; the character immediately after the closing delimiter
    /// must not equal the closing's last character.
    private func delimiterIsIsolated(open: String, close: String,
                                     openAt: Int, closeAt: Int, in ns: NSString) -> Bool {
        let openFirst = (open as NSString).character(at: 0)
        let closeLen = (close as NSString).length
        let closeLast = (close as NSString).character(at: closeLen - 1)
        if openAt > 0, ns.character(at: openAt - 1) == openFirst { return false }
        let afterClose = closeAt + closeLen
        if afterClose < ns.length, ns.character(at: afterClose) == closeLast { return false }
        return true
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

    // MARK: - List-type helpers

    /// True when `line` is a checklist item (`- [ ] ` or `- [x] `).
    func isChecklistLine(_ line: String) -> Bool {
        let ns = line as NSString
        return ns.length >= 6
            && ns.substring(to: 3) == "- ["
            && ns.substring(with: NSRange(location: 4, length: 2)) == "] "
    }

    /// True when `line` is a plain bullet (`- `, `* `, `+ `) but NOT a checklist.
    func isBulletLine(_ line: String) -> Bool {
        guard line.count >= 2 else { return false }
        let start = String(line.prefix(2))
        return (start == "- " || start == "* " || start == "+ ") && !isChecklistLine(line)
    }

    /// Strips any leading list marker (checklist, bullet, numbered) from `line`,
    /// leaving just the content. Returns `line` unchanged if none is detected.
    func stripListPrefix(_ line: String) -> String {
        if isChecklistLine(line) { return String(line.dropFirst(6)) }
        if isBulletLine(line) { return String(line.dropFirst(2)) }
        if leadingListNumber(line) != nil { return stripLeadingNumber(line) }
        return line
    }

    // MARK: - Link detection

    /// The range of the `[text](url)` link that contains the caret, or nil.
    /// Handles carets in both the `[text]` and `(url)` parts.
    func linkRangeAroundCaret() -> NSRange? {
        let ns = rawSource as NSString
        let caret = selectedRange().location
        guard ns.length > 0, caret <= ns.length else { return nil }

        // Try path A: caret is in [text]. Scan backward for '[', bail on ']'/newline.
        var i = caret
        while i > 0 {
            i -= 1
            let c = ns.character(at: i)
            if c == 0x5B { break }
            if c == 0x5D || c == 0x0A { i = -1; break }
        }
        if i >= 0, i < ns.length, ns.character(at: i) == 0x5B {
            if let r = linkRange(ns: ns, from: i, mustContain: caret) { return r }
        }

        // Try path B: caret is in (url). Scan backward for '(', then locate '[' before ']'.
        var p = caret
        while p > 0 {
            p -= 1
            let c = ns.character(at: p)
            if c == 0x28 { break }          // '('
            if c == 0x0A { p = -1; break }
        }
        if p >= 0, ns.character(at: p) == 0x28,
           p > 0, ns.character(at: p - 1) == 0x5D {  // '(' preceded by ']'
            var q = p - 2
            while q >= 0 {
                let c = ns.character(at: q)
                if c == 0x5B { break }
                if c == 0x5D || c == 0x0A { q = -1; break }
                q -= 1
            }
            if q >= 0, ns.character(at: q) == 0x5B {
                if let r = linkRange(ns: ns, from: q, mustContain: caret) { return r }
            }
        }
        return nil
    }

    private func linkRange(ns: NSString, from openBracket: Int, mustContain caret: Int) -> NSRange? {
        var j = openBracket + 1
        while j < ns.length, ns.character(at: j) != 0x5D, ns.character(at: j) != 0x0A { j += 1 }
        guard j < ns.length, ns.character(at: j) == 0x5D else { return nil }
        guard j + 1 < ns.length, ns.character(at: j + 1) == 0x28 else { return nil }
        var k = j + 2
        while k < ns.length, ns.character(at: k) != 0x29, ns.character(at: k) != 0x0A { k += 1 }
        guard k < ns.length, ns.character(at: k) == 0x29 else { return nil }
        let r = NSRange(location: openBracket, length: k - openBracket + 1)
        return (caret >= r.location && caret <= r.upperBound) ? r : nil
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
