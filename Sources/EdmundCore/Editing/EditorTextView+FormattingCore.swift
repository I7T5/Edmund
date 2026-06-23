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

    /// Apply a per-line `transform` over the selected line range.
    ///
    /// Caret repositioning: the caret tracks the first line, shifted by however
    /// many characters that line's prefix changed by (e.g. adding "- " moves the
    /// caret two positions right). With a multi-line selection the whole new
    /// content is re-selected (excluding any trailing newline).
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

    /// Wrap the selection (or caret) in `open`…`close`, or unwrap when already wrapped.
    ///
    /// ## Whitespace stripping
    /// Leading and trailing spaces are excluded from the delimiters, so selecting
    /// `" word "` and pressing Cmd+B yields `" **word** "`, not `"** word **"`.
    /// Toggle-off detection also uses the trimmed range.
    ///
    /// ## Toggle-off detection (selection path)
    /// Three checks, tried in order:
    ///  1. Delimiter pair sits immediately around the trimmed selection. An isolation
    ///     guard prevents a false match when the selection content (`"word"` after Cmd+B)
    ///     is inside a LONGER delimiter run: e.g. `*` at position 1 of `**word**` is not
    ///     an italic delimiter — it is the inner character of the bold `**`. Without the
    ///     guard, Cmd+B → Cmd+I would toggle italic OFF instead of adding it, producing
    ///     `*word*` rather than `***word***`.
    ///  2. The trimmed selection itself starts and ends with the delimiter strings
    ///     (user selected `**word**` and pressed Cmd+B).
    ///
    /// ## Toggle-off detection (caret path)
    /// Three checks, tried in order:
    ///  1. Empty delimiters straddle the caret → remove them.
    ///  2. The current word is wrapped by `open`/`close` (nearest-neighbour search) →
    ///     unwrap. No isolation guard here, so peeling one layer from `***word***` works:
    ///     Cmd+B finds `**` at word.location-2 and correctly removes it.
    ///  3. Fallback: insert empty `open+close` with the caret centred. When
    ///     `expandToWord` is true, the current word is wrapped instead.
    func toggleInlineWrap(open: String, close: String, expandToWord: Bool = false) {
        let ns = rawSource as NSString
        let sel = selectedRange()
        let openLen = (open as NSString).length
        let closeLen = (close as NSString).length

        if sel.length > 0 {
            let selText = ns.substring(with: sel)

            // Whitespace stripping: exclude leading/trailing spaces from the wrap
            // so "  word  " → "  **word**  " instead of "**  word  **".
            let leading = selText.prefix(while: { $0 == " " || $0 == "\t" }).count
            let trailing = selText.reversed().prefix(while: { $0 == " " || $0 == "\t" }).count
            let hasContent = leading + trailing < sel.length
            let effLead = hasContent ? leading : 0
            let effTrail = hasContent ? trailing : 0
            let trimmedSel = NSRange(location: sel.location + effLead,
                                     length: sel.length - effLead - effTrail)
            let trimmedText = ns.substring(with: trimmedSel)

            // Check 1: delimiters sit immediately around the trimmed selection.
            // The isolation guard rejects matches where the found delimiter is part of
            // a longer run: e.g. the `*` at offset 1 of `**word**` is the inner char
            // of `**`, not a standalone `*`. Without the guard, selecting the bare
            // content of a bold word and pressing Cmd+I would fire here and unwrap
            // instead of compounding to `***word***`.
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

            // Check 2: the trimmed selection itself IS the wrapped text.
            let trimmedLen = (trimmedText as NSString).length
            if trimmedLen >= openLen + closeLen,
               trimmedText.hasPrefix(open), trimmedText.hasSuffix(close) {
                let innerLen = trimmedLen - openLen - closeLen
                let inner = (trimmedText as NSString).substring(with: NSRange(location: openLen, length: innerLen))
                applyFormattingEdit(rawRange: trimmedSel, replacement: inner,
                                    select: NSRange(location: trimmedSel.location, length: innerLen))
                return
            }

            // Wrap on — apply only to the non-whitespace content, leaving leading/
            // trailing spaces outside the delimiters.
            let leadStr = String(selText.prefix(effLead))
            let trailStr = String(selText.suffix(effTrail))
            let replacement = leadStr + open + trimmedText + close + trailStr
            // Caret: inside the new delimiters, on the first char of the content.
            applyFormattingEdit(rawRange: sel, replacement: replacement,
                                select: NSRange(location: sel.location + effLead + openLen,
                                                length: trimmedSel.length))
            return
        }

        let caret = sel.location
        // Caret check 1: empty delimiters straddle the caret → remove.
        // E.g. `**|**` → pressing Cmd+B again removes the pair.
        if caret - openLen >= 0, caret + closeLen <= ns.length,
           ns.substring(with: NSRange(location: caret - openLen, length: openLen)) == open,
           ns.substring(with: NSRange(location: caret, length: closeLen)) == close {
            applyFormattingEdit(rawRange: NSRange(location: caret - openLen, length: openLen + closeLen),
                                replacement: "",
                                select: NSRange(location: caret - openLen, length: 0))
            return
        }
        // Caret check 2: nearest word is wrapped → unwrap (nearest-neighbour, no
        // isolation guard so peeling one layer from `***word***` works correctly).
        // E.g. caret in `***word***` + Cmd+B: finds `**` at word.location-2 and peels
        // it, giving `*word*`. The same caret + Cmd+I finds `*` at word.location-1
        // and peels that, giving `**word**`.
        if let word = currentWordRange() {
            let before = word.location - openLen
            if before >= 0, word.upperBound + closeLen <= ns.length,
               ns.substring(with: NSRange(location: before, length: openLen)) == open,
               ns.substring(with: NSRange(location: word.upperBound, length: closeLen)) == close {
                let inner = ns.substring(with: word)
                let full = NSRange(location: before, length: openLen + word.length + closeLen)
                // Caret lands where it was but shifted left by openLen (delimiters removed).
                applyFormattingEdit(rawRange: full, replacement: inner,
                                    select: NSRange(location: caret - openLen, length: 0))
                return
            }
            // Caret check 2b: no wrapping found — wrap the whole word under the caret.
            // Used by the symmetric inline styles (Bold, Italic, …) and Wikilink so
            // that `anyth|ing` + Cmd+B → `**anyth|ing**`. The caret keeps its position
            // within the word (shifted right by the opening delimiter), so the word
            // text isn't disturbed and a second press re-detects + unwraps it.
            if expandToWord {
                let wordText = ns.substring(with: word)
                let replacement = open + wordText + close
                applyFormattingEdit(rawRange: word, replacement: replacement,
                                    select: NSRange(location: caret + openLen, length: 0))
                return
            }
        }
        // Fallback: insert empty delimiters; caret centred between them.
        applyFormattingEdit(rawRange: NSRange(location: caret, length: 0),
                            replacement: open + close,
                            select: NSRange(location: caret + openLen, length: 0))
    }

    /// Toggle `*`-based emphasis using markdown's nesting semantics, where the run
    /// of `*` around a span encodes both styles (1 = italic, 2 = bold, 3 = both).
    /// `stars` is 2 for Bold, 1 for Italic. This lets the two compose at a caret:
    ///
    ///   plain     → Cmd+B → `**w**`     (bold on)
    ///   `**w**`   → Cmd+I → `***w***`   (italic added — compound)
    ///   `***w***` → Cmd+B → `*w*`       (bold removed)
    ///   `***w***` → Cmd+I → `**w**`     (italic removed)
    ///
    /// With a selection it defers to `toggleInlineWrap`, which already compounds
    /// (selecting the inner text adds a layer) and peels (selecting a `**…**` span
    /// strips it). With a bare caret it reads the symmetric run of `*` surrounding
    /// the current word and adds/removes exactly `stars` of them; when the caret is
    /// not in a word it inserts/removes empty delimiters like `toggleInlineWrap`.
    func toggleStarEmphasis(stars: Int) {
        let delim = String(repeating: "*", count: stars)
        let sel = selectedRange()
        if sel.length > 0 {
            toggleInlineWrap(open: delim, close: delim)
            return
        }

        let ns = rawSource as NSString
        let caret = sel.location

        // Empty delimiters straddle the caret → remove them.
        if caret - stars >= 0, caret + stars <= ns.length,
           ns.substring(with: NSRange(location: caret - stars, length: stars)) == delim,
           ns.substring(with: NSRange(location: caret, length: stars)) == delim {
            applyFormattingEdit(rawRange: NSRange(location: caret - stars, length: stars * 2),
                                replacement: "", select: NSRange(location: caret - stars, length: 0))
            return
        }

        guard let word = currentWordRange() else {
            // No word under the caret: insert empty delimiters, caret centred.
            applyFormattingEdit(rawRange: NSRange(location: caret, length: 0),
                                replacement: delim + delim,
                                select: NSRange(location: caret + stars, length: 0))
            return
        }

        // The symmetric run of `*` immediately surrounding the word.
        var leftRun = 0
        while word.location - leftRun - 1 >= 0,
              ns.character(at: word.location - leftRun - 1) == 0x2A { leftRun += 1 }
        var rightRun = 0
        while word.upperBound + rightRun < ns.length,
              ns.character(at: word.upperBound + rightRun) == 0x2A { rightRun += 1 }
        let run = min(leftRun, rightRun)

        // Bold present iff ≥2 stars; italic present iff an odd star count (1 or 3).
        let present = (stars == 2) ? (run >= 2) : (run % 2 == 1)
        let newRun = present ? run - stars : run + stars

        let wordText = ns.substring(with: word)
        let starsStr = String(repeating: "*", count: newRun)
        let full = NSRange(location: word.location - run, length: run + word.length + run)
        // Caret keeps its position within the word, shifted by the star-count change.
        let newCaret = caret + (newRun - run)
        applyFormattingEdit(rawRange: full, replacement: starsStr + wordText + starsStr,
                            select: NSRange(location: newCaret, length: 0))
    }

    /// Returns false when the delimiter at `openAt`/`closeAt` is part of a longer
    /// run of the same character — indicating it is an inner char of a wider delimiter,
    /// not a standalone one of the type we matched.
    ///
    /// Example: `*` at position 1 of `**word**` has `*` at position 0 to its left,
    /// so it is NOT an isolated italic `*`; it is the inner character of the bold `**`.
    ///
    /// This guard is applied ONLY to the selection-path Check 1. The caret word-check
    /// does NOT use it, so that pressing Cmd+B with the caret inside `***word***`
    /// correctly finds and peels the `**` at word.location-2.
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
    ///
    /// Used by all three list commands to implement "replace" semantics: applying
    /// any list type first strips the current marker so lists replace each other
    /// instead of nesting (e.g. `- [ ] task` → Cmd+B → `- task`, not `- - [ ] task`).
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

        // Path A: caret is in [text]. Scan backward for '[', bail on ']'/newline.
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

        // Path B: caret is in (url). Scan backward for '(', then locate '[' before ']'.
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
