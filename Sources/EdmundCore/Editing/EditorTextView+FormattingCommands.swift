import AppKit

// MARK: - Format-menu actions
//
// Public @objc action methods targeted by the Format menu (nil-target items
// route through the responder chain to the focused editor — the same wiring as
// undo/redo). Each delegates to a primitive/helper in +FormattingCore.
//
// ## Invertibility
//
// Most format commands are toggles: applying twice returns to the original text
// and cursor position. Exceptions:
//   • Checklist (⌘L)  — NOT invertible. Re-applying cycles [ ] ↔ [x] instead of
//                        removing the checklist marker.
//   • Footnote        — NOT invertible. Inserts a new [^n] each time.
//   • Table           — NOT a toggle. Always inserts a fresh placeholder table.
//
// ## Caret repositioning
//
// After wrap-on (no selection or wrap-off leaves content selected):
//   • Symmetric inline styles (Bold, Italic, …): caret placed on the first char
//     of the wrapped content — so the next keystroke edits inside the delimiters.
//   • Link/Image (no selection): caret lands inside the `()` so the URL can be
//     typed immediately.
//   • Link/Wikilink/Image (selection or word expansion): caret inside `()` or
//     after content.
//   • Footnote: caret at the end-of-file definition line, ready to type the note.
//   • Math Block / Code Block: caret on the opening-fence line (language / math
//     content).
//   • Table: caret on the first header cell.
//
// ## List replacement
//
// Applying any list format (Bulleted / Numbered / Checklist) to a line that
// already carries a different list marker strips the old marker first (via
// stripListPrefix), so lists replace rather than nest:
//   `- [ ] task` → ⌥⌘B  →  `- task`   (not `- - [ ] task`)
//   `1. item`    → ⌘L   →  `- [ ] item`
//
// ## Whitespace stripping
//
// Inline wraps (Bold, Italic, Code, etc.) exclude leading/trailing spaces from
// the delimiters: selecting " word " and pressing Cmd+B gives " **word** ", not
// "** word **". Toggle-off detection also operates on the trimmed range, so
// selecting " **word** " and pressing Cmd+B correctly unwraps.

extension EditorTextView {

    // MARK: - Inline font styles
    // All toggle (applying twice restores original).
    //
    // Caret-with-no-selection behaviour: a caret INSIDE a word acts on the whole
    // word (`anyth|ing` + Cmd+B → `**anything**`); pressing again unwraps it. When
    // the caret is not in a word (blank line, between punctuation), empty delimiters
    // are inserted with the caret centred (`**|**`).
    //
    // Bold and Italic additionally use markdown's `*`-nesting semantics at a caret,
    // so the two compose: `**w**` + Cmd+I → `***w***`, and `***w***` + Cmd+B →
    // `*w*`. See toggleStarEmphasis. The other styles use the generic word wrap
    // (expandToWord), since they don't nest with each other.

    @objc public func formatBold(_ sender: Any?)          { toggleStarEmphasis(stars: 2) }
    @objc public func formatItalic(_ sender: Any?)        { toggleStarEmphasis(stars: 1) }
    @objc public func formatUnderline(_ sender: Any?)     { toggleInlineWrap(open: "<u>", close: "</u>", expandToWord: true) }
    @objc public func formatStrikethrough(_ sender: Any?) { toggleInlineWrap(open: "~~", close: "~~", expandToWord: true) }
    @objc public func formatHighlight(_ sender: Any?)     { toggleInlineWrap(open: "==", close: "==", expandToWord: true) }
    @objc public func formatCode(_ sender: Any?)          { toggleInlineWrap(open: "`", close: "`", expandToWord: true) }
    @objc public func formatInlineMath(_ sender: Any?)    { toggleInlineWrap(open: "$", close: "$", expandToWord: true) }
    @objc public func formatKeyboard(_ sender: Any?)      { toggleInlineWrap(open: "<kbd>", close: "</kbd>", expandToWord: true) }
    @objc public func formatComment(_ sender: Any?)       { toggleInlineWrap(open: "%%", close: "%%", expandToWord: true) }

    // MARK: - Inline links
    // Link / Image: caret in `()` so URL can be typed next.
    // Wikilink:     expands to the current word at caret (expandToWord: true).
    // Footnote:     NOT invertible — inserts [^n] marker and EOF definition.

    @objc public func formatWikilink(_ sender: Any?)      { toggleInlineWrap(open: "[[", close: "]]", expandToWord: true) }
    @objc public func formatLink(_ sender: Any?)          { insertLink() }
    @objc public func formatImage(_ sender: Any?)         { insertImage() }
    @objc public func formatFootnote(_ sender: Any?)      { insertFootnote() }

    // MARK: - Block-level commands

    @objc public func formatBulletedList(_ sender: Any?)  { toggleLinePrefix("- ") }
    @objc public func formatNumberedList(_ sender: Any?)  { toggleNumberedList() }
    @objc public func formatChecklist(_ sender: Any?)     { toggleChecklist() }
    @objc public func formatBlockQuote(_ sender: Any?)    { toggleLinePrefix("> ") }
    @objc public func formatThematicBreak(_ sender: Any?) { insertThematicBreak() }
    @objc public func formatCodeBlock(_ sender: Any?)     { insertCodeBlock() }
    @objc public func formatMathBlock(_ sender: Any?)     { insertMathBlock() }
    @objc public func formatTable(_ sender: Any?)         { insertTable() }

    /// Heading level read from the menu item's `tag` (1–6).
    /// Heading H1–H6: strips any existing `#…` prefix and applies the new level.
    /// Re-applying the same level clears the heading. Applies per selected line.
    @objc public func formatHeading(_ sender: Any?) {
        applyHeadingLevel((sender as? NSMenuItem)?.tag ?? 1)
    }

    /// Callout type read from the menu item's `representedObject` (pre-cased:
    /// uppercase for GitHub alerts, lowercase for Obsidian callouts).
    @objc public func formatCallout(_ sender: Any?) {
        guard let type = (sender as? NSMenuItem)?.representedObject as? String else { return }
        applyCalloutType(type)
    }

    // MARK: - Menu validation
    // Formatting actions are disabled in Reading mode (the editor is read-only).

    public override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let action = menuItem.action, Self.formattingActions.contains(action) {
            return viewMode != .reading
        }
        return super.validateMenuItem(menuItem)
    }

    static let formattingActions: Set<Selector> = [
        #selector(formatBold(_:)), #selector(formatItalic(_:)), #selector(formatUnderline(_:)),
        #selector(formatStrikethrough(_:)), #selector(formatHighlight(_:)), #selector(formatCode(_:)),
        #selector(formatInlineMath(_:)), #selector(formatKeyboard(_:)), #selector(formatComment(_:)),
        #selector(formatWikilink(_:)), #selector(formatLink(_:)), #selector(formatImage(_:)),
        #selector(formatFootnote(_:)), #selector(formatBulletedList(_:)), #selector(formatNumberedList(_:)),
        #selector(formatChecklist(_:)), #selector(formatBlockQuote(_:)), #selector(formatThematicBreak(_:)),
        #selector(formatCodeBlock(_:)), #selector(formatMathBlock(_:)), #selector(formatTable(_:)),
        #selector(formatHeading(_:)), #selector(formatCallout(_:)),
    ]

    // MARK: - Heading

    func applyHeadingLevel(_ level: Int) {
        // All selected lines get the same heading level applied or cleared.
        // "Same level" is determined by majority: if every non-empty line already
        // has exactly `level` hashes, they are all cleared (toggle-off).
        transformSelectedLines { lines in
            let nonEmpty = lines.filter { !$0.isEmpty }
            let allAtLevel = !nonEmpty.isEmpty && nonEmpty.allSatisfy { self.leadingHashCount($0) == level }
            return lines.map { line in
                guard !line.isEmpty else { return line }
                let stripped = self.stripLeadingHashes(line)
                return allAtLevel ? stripped : String(repeating: "#", count: level) + " " + stripped
            }
        }
    }

    // MARK: - Lists / quote

    /// Prepend `prefix` to every line, or strip it when every non-empty line is
    /// already that exact type (toggle-off).
    ///
    /// List replacement: for bullet prefixes (`"- "` etc.), any existing list
    /// marker (checklist, numbered, other bullet) is stripped before the new one
    /// is applied, so list types replace each other rather than stacking. Block
    /// quotes (`"> "`) are not list markers; they stack normally.
    ///
    /// Toggle-off check: only fires when every non-empty line is EXACTLY this
    /// bullet type — not checklists (which also start with `"- "` but are a
    /// different type) or numbered lists.
    func toggleLinePrefix(_ prefix: String) {
        let isList = (prefix == "- " || prefix == "* " || prefix == "+ ")
        transformSelectedLines { lines in
            let nonEmpty = lines.filter { !$0.isEmpty }
            let stripAll: Bool
            if isList {
                // Toggle-off only for exact bullets, not checklists or numbered.
                stripAll = !nonEmpty.isEmpty && nonEmpty.allSatisfy { self.isBulletLine($0) && $0.hasPrefix(prefix) }
            } else {
                stripAll = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.hasPrefix(prefix) }
            }
            if stripAll {
                return lines.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
            }
            if lines == [""] { return [prefix] }
            return lines.map { line -> String in
                guard !line.isEmpty else { return line }
                // Strip existing list marker before adding new one (replacement, not nesting).
                return isList ? prefix + self.stripListPrefix(line) : prefix + line
            }
        }
    }

    /// Numbered list: prepend `1.`, `2.`, … per line (toggle-off strips the
    /// prefix). If the line immediately before the selection ends with `N. `,
    /// numbering continues from N+1 rather than restarting at 1.
    /// Replacement: strips any existing list marker before numbering.
    func toggleNumberedList() {
        let ns = rawSource as NSString
        let ctx = selectedLineContext()

        var start = 1
        if ctx.range.location > 0 {
            let prev = ns.lineRange(for: NSRange(location: ctx.range.location - 1, length: 0))
            var prevLine = ns.substring(with: prev)
            if prevLine.hasSuffix("\n") { prevLine.removeLast() }
            if let n = leadingListNumber(prevLine) { start = n + 1 }
        }

        transformSelectedLines { lines in
            let nonEmpty = lines.filter { !$0.isEmpty }
            let allNumbered = !nonEmpty.isEmpty && nonEmpty.allSatisfy { self.leadingListNumber($0) != nil }
            if allNumbered {
                return lines.map { self.stripListPrefix($0) }
            }
            if lines == [""] { return ["\(start). "] }
            var n = start
            return lines.map { line -> String in
                guard !line.isEmpty else { return line }
                defer { n += 1 }
                return "\(n). " + self.stripListPrefix(line)
            }
        }
    }

    /// Checklist (NOT invertible):
    ///   • Checklist line: toggles the mark `[ ]` ↔ `[x]`.
    ///   • Any other line (plain, bullet, numbered): strips the existing list
    ///     marker and prepends `- [ ] ` (replacement, not nesting).
    func toggleChecklist() {
        transformSelectedLines { lines in
            lines.map { line in
                if self.isChecklistLine(line) {
                    let ns = line as NSString
                    let mark = ns.character(at: 3)
                    let newMark = (mark == 0x20) ? "x" : " "   // ' ' ↔ 'x'
                    return "- [" + newMark + "] " + ns.substring(from: 6)
                }
                // Strip existing list marker before adding checklist prefix.
                return "- [ ] " + self.stripListPrefix(line)
            }
        }
    }

    // MARK: - Link / Image / Footnote

    /// Link (⌘K): toggle.
    /// • With selection: wraps as `[selection]()`, caret in `()`. If the selection
    ///   is already `[text](dest)`, unwraps to the text.
    /// • No selection: if caret is inside an existing `[text](url)`, unwraps it.
    ///   Otherwise expands to the current word, producing `[word]()`, caret in `()`.
    ///   Fallback (no word): inserts `[]()`, caret in `()`.
    private func insertLink() {
        let ns = rawSource as NSString
        let sel = selectedRange()

        if sel.length > 0 {
            let text = ns.substring(with: sel)
            if let inner = unwrapLink(text) {
                applyFormattingEdit(rawRange: sel, replacement: inner,
                                    select: NSRange(location: sel.location, length: (inner as NSString).length))
                return
            }
            let replacement = "[" + text + "]()"
            let caret = sel.location + 1 + (text as NSString).length + 2  // inside ()
            applyFormattingEdit(rawRange: sel, replacement: replacement,
                                select: NSRange(location: caret, length: 0))
            return
        }

        // Caret: check if inside an existing link → unwrap.
        if let linkRange = linkRangeAroundCaret() {
            let linkText = ns.substring(with: linkRange)
            if let inner = unwrapLink(linkText) {
                applyFormattingEdit(rawRange: linkRange, replacement: inner,
                                    select: NSRange(location: linkRange.location, length: (inner as NSString).length))
                return
            }
        }

        // Expand to current word.
        if let word = currentWordRange() {
            let wordText = ns.substring(with: word)
            let replacement = "[" + wordText + "]()"
            let caret = word.location + 1 + (wordText as NSString).length + 2  // inside ()
            applyFormattingEdit(rawRange: word, replacement: replacement,
                                select: NSRange(location: caret, length: 0))
            return
        }

        // No word: insert empty link, caret inside ().
        applyFormattingEdit(rawRange: NSRange(location: sel.location, length: 0),
                            replacement: "[]()",
                            select: NSRange(location: sel.location + 3, length: 0))
    }

    /// Image: same shape as Link, prefixed with `!`.
    /// Caret ends up inside the `()` so the URL/path can be typed.
    private func insertImage() {
        let ns = rawSource as NSString
        let sel = selectedRange()

        if sel.length > 0 {
            let text = ns.substring(with: sel)
            if let inner = unwrapImage(text) {
                applyFormattingEdit(rawRange: sel, replacement: inner,
                                    select: NSRange(location: sel.location, length: (inner as NSString).length))
                return
            }
            let replacement = "![" + text + "]()"
            let caret = sel.location + 2 + (text as NSString).length + 2  // inside ()
            applyFormattingEdit(rawRange: sel, replacement: replacement,
                                select: NSRange(location: caret, length: 0))
            return
        }

        if let word = currentWordRange() {
            let wordText = ns.substring(with: word)
            let replacement = "![" + wordText + "]()"
            let caret = word.location + 2 + (wordText as NSString).length + 2  // inside ()
            applyFormattingEdit(rawRange: word, replacement: replacement,
                                select: NSRange(location: caret, length: 0))
            return
        }

        applyFormattingEdit(rawRange: NSRange(location: sel.location, length: 0),
                            replacement: "![]()",
                            select: NSRange(location: sel.location + 4, length: 0))
    }

    /// Footnote (NOT invertible): inserts `[^n]` after the selection / end of
    /// current word / caret, then appends `[^n]: ` at the end of the document.
    /// Caret lands at the EOF definition so the note body can be typed immediately.
    /// `n` is the next unused number (max existing [^k] + 1, starting at 1).
    private func insertFootnote() {
        let ns = rawSource as NSString
        let sel = selectedRange()
        let n = nextFootnoteNumber()

        // Insertion point: after selection, or after the current word, or at caret.
        let markerPos: Int
        if sel.length > 0 {
            markerPos = sel.upperBound
        } else if let word = currentWordRange() {
            markerPos = word.upperBound
        } else {
            markerPos = sel.location
        }

        var newRaw = ns.replacingCharacters(in: NSRange(location: markerPos, length: 0),
                                            with: "[^\(n)]")
        let body = newRaw as NSString
        // A blank line (not just a single \n) before the definition so it parses
        // as its own paragraph rather than a lazy-continuation line of the
        // reference's paragraph — CommonMark (and Read mode's HTMLRenderer, which
        // parses the whole document) needs that separation to recognize it as a
        // footnote definition rather than fused body text.
        var trailingNewlines = 0
        var i = body.length - 1
        while i >= 0 && body.character(at: i) == 0x0A { trailingNewlines += 1; i -= 1 }
        let separator = body.length == 0 ? "" : String(repeating: "\n", count: max(0, 2 - trailingNewlines))
        newRaw += separator + "[^\(n)]: "
        let caret = (newRaw as NSString).length
        applyWholeDocumentEdit(newRawSource: newRaw, select: NSRange(location: caret, length: 0))
    }

    // MARK: - Block insert

    /// Code block: wraps selected lines in ` ``` `…` ``` ` fences (toggle-off removes
    /// them). Caret lands on the opening-fence line so a language tag can be typed.
    private func insertCodeBlock() {
        let ctx = selectedLineContext()
        if ctx.lines.count >= 2, ctx.lines.first!.hasPrefix("```"), ctx.lines.last! == "```" {
            // Toggle off: unwrap the fenced content.
            let inner = ctx.lines.dropFirst().dropLast().joined(separator: "\n")
            var replacement = inner
            if ctx.trailingNewline { replacement += "\n" }
            applyFormattingEdit(rawRange: ctx.range, replacement: replacement,
                                select: NSRange(location: ctx.range.location, length: 0))
            return
        }
        let content = ctx.lines.joined(separator: "\n")
        var replacement = "```\n" + content + "\n```"
        if ctx.trailingNewline { replacement += "\n" }
        // Caret after the opening "```" so a language tag can be typed.
        applyFormattingEdit(rawRange: ctx.range, replacement: replacement,
                            select: NSRange(location: ctx.range.location + 3, length: 0))
    }

    /// Math block: wraps selected lines in `$$`…`$$` fences (toggle-off removes
    /// them). Each `$$` occupies its own line (block math format).
    /// Caret lands on the first content line between the fences.
    private func insertMathBlock() {
        let ctx = selectedLineContext()
        if ctx.lines.count >= 2, ctx.lines.first! == "$$", ctx.lines.last! == "$$" {
            let inner = ctx.lines.dropFirst().dropLast().joined(separator: "\n")
            var replacement = inner
            if ctx.trailingNewline { replacement += "\n" }
            applyFormattingEdit(rawRange: ctx.range, replacement: replacement,
                                select: NSRange(location: ctx.range.location, length: 0))
            return
        }
        let content = ctx.lines.joined(separator: "\n")
        var replacement = "$$\n" + content + "\n$$"
        if ctx.trailingNewline { replacement += "\n" }
        // Caret on the first content line (after the opening "$$\n").
        applyFormattingEdit(rawRange: ctx.range, replacement: replacement,
                            select: NSRange(location: ctx.range.location + 3, length: 0))
    }

    /// Table: inserts a 3×2 placeholder table (3 columns, 2 data rows) after the
    /// current line. Not a toggle. Dividers are padded to match header widths (8 chars).
    /// Caret lands on the first header cell.
    private func insertTable() {
        let ns = rawSource as NSString
        let sel = selectedRange()
        let line = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        let lineEndsWithNewline = line.upperBound > line.location && ns.character(at: line.upperBound - 1) == 0x0A
        let lineIsBlank = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // 3 columns; dividers padded to "Header N" length (8 dashes).
        let table = """
            | Header 1 | Header 2 | Header 3 |
            | -------- | -------- | -------- |
            | Cell 1 | Cell 2 | Cell 3 |
            | Cell 4 | Cell 5 | Cell 6 |

            """
        let insertPos: Int
        let replacement: String
        let lead: Int
        if lineIsBlank {
            insertPos = line.location
            replacement = table
            lead = 0
        } else if lineEndsWithNewline {
            insertPos = line.upperBound
            replacement = table
            lead = 0
        } else {
            insertPos = ns.length
            replacement = "\n" + table
            lead = 1
        }
        let caret = insertPos + lead + 2   // past leading newline (if any) + "| "
        applyFormattingEdit(rawRange: NSRange(location: insertPos, length: 0),
                            replacement: replacement,
                            select: NSRange(location: caret, length: 0))
    }

    // MARK: - Thematic break

    /// Thematic break (horizontal rule): inserts `---` on its own line.
    /// Toggle-off: if the selected line is exactly `---`, removes it.
    ///
    /// Insertion rules:
    ///   • Empty line — replace the line with `---\n` (the caret is already on
    ///     an isolated line, so no separator is needed).
    ///   • Non-empty line — insert `\n---\n` after the line end; prepend an
    ///     extra `\n` when the line has no trailing newline (last line, no EOF
    ///     newline) so the `---` isn't parsed as a setext heading underline.
    ///
    /// Caret lands after `---\n` so the next paragraph can be typed immediately.
    private func insertThematicBreak() {
        let ns = rawSource as NSString
        let ctx = selectedLineContext()

        if ctx.lines == ["---"] {
            applyFormattingEdit(rawRange: ctx.range, replacement: "",
                                select: NSRange(location: ctx.range.location, length: 0))
            return
        }

        let sel = selectedRange()
        let line = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0))

        // Empty line: replace just the line content with "---\n".
        if ctx.lines == [""] {
            let replacement = "---\n"
            applyFormattingEdit(rawRange: ctx.range, replacement: replacement,
                                select: NSRange(location: ctx.range.location + 3, length: 0))
            return
        }

        // Non-empty line: insert after the line end.
        let hasTrailingNewline = line.upperBound > line.location
            && ns.character(at: line.upperBound - 1) == 0x0A
        let text = hasTrailingNewline ? "\n---\n" : "\n\n---\n"
        let insertAt = line.upperBound
        let caret = insertAt + (text as NSString).length
        applyFormattingEdit(rawRange: NSRange(location: insertAt, length: 0),
                            replacement: text,
                            select: NSRange(location: min(caret, (rawSource as NSString).length), length: 0))
    }

    // MARK: - Callout / alert

    /// Wrap the selected lines in a callout (`> [!TYPE]` header + `> ` body), or
    /// strip it when the lines are already that callout. `type` is pre-cased
    /// (uppercase for GitHub, lowercase for Obsidian).
    func applyCalloutType(_ type: String) {
        transformSelectedLines { lines in
            let header = "> [!\(type)]"
            if let first = lines.first,
               first.trimmingCharacters(in: .whitespaces).lowercased() == "> [!\(type.lowercased())]" {
                return lines.dropFirst().map {
                    if $0.hasPrefix("> ") { return String($0.dropFirst(2)) }
                    if $0.hasPrefix(">")  { return String($0.dropFirst(1)) }
                    return $0
                }
            }
            let body = lines.map { $0.isEmpty ? ">" : "> " + $0 }
            return [header] + body
        }
    }
}
