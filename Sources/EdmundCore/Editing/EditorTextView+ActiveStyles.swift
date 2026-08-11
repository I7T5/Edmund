import AppKit

// MARK: - Which formatting is in effect at the selection
//
// Read-only counterpart to the toggles in `EditorTextView+FormattingCommands`:
// the commands decide "should this apply or unapply", this decides "is it on
// right now", which is what the format bar's buttons light up from.
//
// Deliberately a delimiter scan over the selected lines rather than a look at
// the rendered text attributes. Storage == rawSource, and the styled attributes
// are lossy in the direction we need: a heading is bold, `==mark==` and a code
// span are both background fills, so "which command produced this" cannot be
// recovered from the font. The source delimiters say it exactly.
//
// Scope is the selected lines. Inline emphasis does not survive a blank line,
// and a scan bounded by the paragraph keeps this cheap enough to run on every
// caret move.

extension EditorTextView {

    /// Inline delimiters that are their own on-state, other than the `*` runs
    /// (which need the run-length logic in `starEmphasisActions`).
    private static let inlineWrapActions: [(Selector, open: String, close: String)] = [
        (#selector(formatUnderline(_:)),     "<u>",   "</u>"),
        (#selector(formatStrikethrough(_:)), "~~",    "~~"),
        (#selector(formatSubscript(_:)),     "<sub>", "</sub>"),
        (#selector(formatSuperscript(_:)),   "<sup>", "</sup>"),
        (#selector(formatHighlight(_:)),     "==",    "=="),
        (#selector(formatCode(_:)),          "`",     "`"),
        (#selector(formatInlineMath(_:)),    "$",     "$"),
        (#selector(formatKeyboard(_:)),      "<kbd>", "</kbd>"),
    ]

    /// The formatting actions currently in effect at the selection — the caret
    /// sits inside the span, or the selection swallows it whole.
    ///
    /// Cheap by construction: one pass over the selected lines per delimiter,
    /// no layout and no styling, so it is safe on every selection change.
    public func activeFormattingActions() -> Set<Selector> {
        let ns = rawSource as NSString
        guard ns.length > 0 else { return [] }
        let sel = clampedSelection(in: ns)
        let lineRange = ns.lineRange(for: sel)
        let line = ns.substring(with: lineRange) as NSString

        var active: Set<Selector> = []
        active.formUnion(starEmphasisActions(in: line, at: lineRange.location, sel: sel))
        for (action, open, close) in Self.inlineWrapActions {
            for span in wrappedSpans(in: line, open: open, close: close)
            where covers(span, sel: sel, lineStart: lineRange.location) {
                active.insert(action)
                break
            }
        }
        active.formUnion(linePrefixActions())
        active.formUnion(fencedBlockActions())
        return active
    }

    /// Code and math blocks, which a line scan cannot see: their fences open a
    /// region that runs past the selected lines, so a caret in the middle of one
    /// has no delimiter on its own line to find. The parsed block list already
    /// knows which region the caret is in, so this reads that instead.
    private func fencedBlockActions() -> Set<Selector> {
        guard let index = blockIndexForRawOffset(selectedRange().location),
              index < blocks.count else { return [] }
        switch blocks[index].kind {
        case .fence, .indentedCode: return [#selector(formatCodeBlock(_:))]
        case .mathDisplay:          return [#selector(formatMathBlock(_:))]
        default:                    return []
        }
    }

    // MARK: - Inline spans

    /// `*` runs paired off into emphasis spans. Run length is what distinguishes
    /// the two commands — `*x*` is italic, `**x**` bold, `***x***` both — so a
    /// plain search for `*` (which would find the inner star of a `**` pair)
    /// cannot answer this and the run length has to be measured.
    private func starEmphasisActions(in line: NSString, at lineStart: Int,
                                     sel: NSRange) -> Set<Selector> {
        var runs: [NSRange] = []
        var i = 0
        while i < line.length {
            guard line.character(at: i) == UInt16(UnicodeScalar("*").value) else { i += 1; continue }
            var end = i
            while end < line.length,
                  line.character(at: end) == UInt16(UnicodeScalar("*").value) { end += 1 }
            runs.append(NSRange(location: i, length: end - i))
            i = end
        }

        var active: Set<Selector> = []
        for pair in stride(from: 0, to: runs.count - 1, by: 2) {
            let open = runs[pair], close = runs[pair + 1]
            // An unbalanced pair (`**bold*`) emphasises only as far as the
            // shorter run reaches.
            let width = min(open.length, close.length)
            let span = (inner: NSRange(location: open.upperBound,
                                       length: close.location - open.upperBound),
                        outer: NSRange(location: open.location,
                                       length: close.upperBound - open.location))
            guard covers(span, sel: sel, lineStart: lineStart) else { continue }
            if width >= 2 { active.insert(#selector(formatBold(_:))) }
            if width % 2 == 1 { active.insert(#selector(formatItalic(_:))) }
        }
        return active
    }

    /// Non-overlapping `open`…`close` spans, scanned left to right. Pairing as
    /// it goes is what keeps `a **b** c **d** e` from reading as one span from
    /// the first delimiter to the last.
    private func wrappedSpans(in line: NSString, open: String,
                              close: String) -> [(inner: NSRange, outer: NSRange)] {
        var spans: [(inner: NSRange, outer: NSRange)] = []
        var from = 0
        while from < line.length {
            let openHit = line.range(of: open, options: [],
                                     range: NSRange(location: from, length: line.length - from))
            guard openHit.location != NSNotFound else { break }
            let afterOpen = openHit.upperBound
            guard afterOpen < line.length else { break }
            let closeHit = line.range(of: close, options: [],
                                      range: NSRange(location: afterOpen,
                                                     length: line.length - afterOpen))
            guard closeHit.location != NSNotFound else { break }
            spans.append((inner: NSRange(location: afterOpen,
                                         length: closeHit.location - afterOpen),
                          outer: NSRange(location: openHit.location,
                                         length: closeHit.upperBound - openHit.location)))
            from = closeHit.upperBound
        }
        return spans
    }

    /// The span counts as active when the caret is anywhere inside the
    /// delimited content, or when the selection contains the whole thing
    /// (delimiters included) — pressing the button in either state is what
    /// would turn the formatting back off.
    private func covers(_ span: (inner: NSRange, outer: NSRange),
                        sel: NSRange, lineStart: Int) -> Bool {
        let inner = NSRange(location: span.inner.location + lineStart, length: span.inner.length)
        let outer = NSRange(location: span.outer.location + lineStart, length: span.outer.length)
        if sel.length == 0 {
            return sel.location >= inner.location && sel.location <= inner.upperBound
        }
        let insideInner = sel.location >= inner.location && sel.upperBound <= inner.upperBound
        let swallowsOuter = sel.location <= outer.location && sel.upperBound >= outer.upperBound
        return insideInner || swallowsOuter
    }

    // MARK: - Pulldown state
    //
    // The two pulldowns each apply one of a set of mutually exclusive things, so
    // their state is the member currently in effect rather than a yes/no — a
    // checkmark in the menu, not a chip on the button.

    /// The heading level shared by every non-empty selected line: 0 for body
    /// text, 1–6 for `#`…`######`. Nil when the lines disagree, matching
    /// `applyHeadingLevel`, which only treats a level as already-applied when
    /// all of them carry it.
    public func activeHeadingLevel() -> Int? {
        let lines = selectedLineContext().lines.filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        let level = leadingHashCount(first)
        return lines.allSatisfy { leadingHashCount($0) == level } ? level : nil
    }

    /// The callout type at the selection, lowercased, or nil when the first
    /// selected line is not a callout header.
    ///
    /// The first line is what `applyCalloutType` reads to decide whether it is
    /// toggling a callout off, so the checkmark and the command agree about
    /// which callout they are looking at. Parsing goes through
    /// `Callout.parseMarker`, the same matcher the renderer uses, so `[!NOTE]`,
    /// `[!note]` and a folded `[!note]-` all resolve alike.
    public func activeCalloutType() -> String? {
        guard let first = selectedLineContext().lines.first else { return nil }
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else { return nil }
        let afterQuote = trimmed.dropFirst().drop { $0 == " " }
        return Callout.parseMarker(String(afterQuote))?.type
    }

    // MARK: - Line prefixes

    /// List and quote state, which is a property of the whole line rather than
    /// of a span. Every non-empty selected line has to match, mirroring the
    /// toggles: they clear the prefix only when all of them carry it.
    private func linePrefixActions() -> Set<Selector> {
        let context = selectedLineContext()
        var active: Set<Selector> = []
        // The same line `insertThematicBreak` recognises when it is removing
        // one, so the button lights exactly when pressing it would undo it.
        if context.lines == ["---"] {
            active.insert(#selector(formatThematicBreak(_:)))
        }
        let lines = context.lines.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return active }
        if lines.allSatisfy({ isBulletLine($0) }) {
            active.insert(#selector(formatBulletedList(_:)))
        }
        if lines.allSatisfy({ isChecklistLine($0) }) {
            active.insert(#selector(formatChecklist(_:)))
        }
        if lines.allSatisfy({ leadingListNumber($0) != nil }) {
            active.insert(#selector(formatNumberedList(_:)))
        }
        // A callout is a block quote underneath, so this would light too. The
        // callout pulldown already reports it, and showing both said the
        // selection was two things at once.
        if lines.allSatisfy({ $0.drop(while: { $0 == " " }).hasPrefix(">") }),
           activeCalloutType() == nil {
            active.insert(#selector(formatBlockQuote(_:)))
        }
        return active
    }

    /// The selection clamped into the current source, so a stale selection left
    /// by an edit cannot walk `lineRange(for:)` off the end.
    private func clampedSelection(in ns: NSString) -> NSRange {
        let location = min(max(0, selectedRange().location), ns.length)
        return NSRange(location: location,
                       length: min(selectedRange().length, ns.length - location))
    }
}
