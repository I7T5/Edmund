import AppKit

// MARK: - Format-menu actions
//
// Public @objc action methods targeted by the Format menu (nil-target items
// route through the responder chain to the focused editor — the same wiring as
// undo/redo). Each delegates to a primitive/helper in +FormattingCore.
//
// Toggling: most commands are invertible — applying twice restores the original
// — except Checklist, Footnote, and Table, which the spec marks otherwise.

extension EditorTextView {

    // MARK: Inline font styles

    @objc public func formatBold(_ sender: Any?)          { toggleInlineWrap(open: "**", close: "**") }
    @objc public func formatItalic(_ sender: Any?)        { toggleInlineWrap(open: "*", close: "*") }
    @objc public func formatUnderline(_ sender: Any?)     { toggleInlineWrap(open: "<u>", close: "</u>") }
    @objc public func formatStrikethrough(_ sender: Any?) { toggleInlineWrap(open: "~~", close: "~~") }
    @objc public func formatHighlight(_ sender: Any?)     { toggleInlineWrap(open: "==", close: "==") }
    @objc public func formatCode(_ sender: Any?)          { toggleInlineWrap(open: "`", close: "`") }
    @objc public func formatInlineMath(_ sender: Any?)    { toggleInlineWrap(open: "$", close: "$") }
    @objc public func formatKeyboard(_ sender: Any?)      { toggleInlineWrap(open: "<kbd>", close: "</kbd>") }
    @objc public func formatComment(_ sender: Any?)       { toggleInlineWrap(open: "%%", close: "%%") }

    // MARK: Inline links

    @objc public func formatWikilink(_ sender: Any?)      { toggleInlineWrap(open: "[[", close: "]]", expandToWord: true) }
    @objc public func formatLink(_ sender: Any?)          { insertLink() }
    @objc public func formatImage(_ sender: Any?)         { insertImage() }
    @objc public func formatFootnote(_ sender: Any?)      { insertFootnote() }

    // MARK: Blocks

    @objc public func formatBulletedList(_ sender: Any?)  { toggleLinePrefix("- ") }
    @objc public func formatNumberedList(_ sender: Any?)  { toggleNumberedList() }
    @objc public func formatChecklist(_ sender: Any?)     { toggleChecklist() }
    @objc public func formatBlockQuote(_ sender: Any?)    { toggleLinePrefix("> ") }
    @objc public func formatCodeBlock(_ sender: Any?)     { insertCodeBlock() }
    @objc public func formatMathBlock(_ sender: Any?)     { insertMathBlock() }
    @objc public func formatTable(_ sender: Any?)         { insertTable() }

    /// Heading level read from the menu item's `tag` (1–6).
    @objc public func formatHeading(_ sender: Any?) {
        applyHeadingLevel((sender as? NSMenuItem)?.tag ?? 1)
    }

    /// Callout type read from the menu item's `representedObject` (already cased:
    /// uppercase for GitHub alerts, lowercase for Obsidian callouts).
    @objc public func formatCallout(_ sender: Any?) {
        guard let type = (sender as? NSMenuItem)?.representedObject as? String else { return }
        applyCalloutType(type)
    }

    // MARK: - Menu validation
    //
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
        #selector(formatChecklist(_:)), #selector(formatBlockQuote(_:)), #selector(formatCodeBlock(_:)),
        #selector(formatMathBlock(_:)), #selector(formatTable(_:)), #selector(formatHeading(_:)),
        #selector(formatCallout(_:)),
    ]

    // MARK: - Heading

    func applyHeadingLevel(_ level: Int) {
        transformSelectedLines { lines in
            let nonEmpty = lines.filter { !$0.isEmpty }
            let allAtLevel = !nonEmpty.isEmpty && nonEmpty.allSatisfy { self.leadingHashCount($0) == level }
            return lines.map { line in
                guard !line.isEmpty else { return line }
                let stripped = self.stripLeadingHashes(line)
                // Re-applying the same level clears the heading.
                return allAtLevel ? stripped : String(repeating: "#", count: level) + " " + stripped
            }
        }
    }

    // MARK: - Lists / quote

    /// Prepend `prefix` to every line, or strip it when every non-empty line is
    /// already that exact type (toggle). For list prefixes (`"- "` etc.) existing
    /// other list markers are stripped before the new prefix is applied, so lists
    /// seamlessly replace each other (bullet→numbered, checklist→bullet, etc.).
    func toggleLinePrefix(_ prefix: String) {
        let isList = (prefix == "- " || prefix == "* " || prefix == "+ ")
        transformSelectedLines { lines in
            let nonEmpty = lines.filter { !$0.isEmpty }
            // Toggle off only when every non-empty line is exactly this list type.
            let stripAll: Bool
            if isList {
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
                return isList ? prefix + self.stripListPrefix(line) : prefix + line
            }
        }
    }

    func toggleNumberedList() {
        let ns = rawSource as NSString
        let ctx = selectedLineContext()

        // Continue numbering from the line before the selection, if it is a list.
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

    /// Checklist (NOT invertible): non-checklist lines gain `- [ ] ` (stripping
    /// any existing list marker first); existing checklist lines toggle `[ ]`↔`[x]`.
    func toggleChecklist() {
        transformSelectedLines { lines in
            lines.map { line in
                if self.isChecklistLine(line) {
                    let ns = line as NSString
                    let mark = ns.character(at: 3)
                    let newMark = (mark == 0x20) ? "x" : " "
                    return "- [" + newMark + "] " + ns.substring(from: 6)
                }
                return "- [ ] " + self.stripListPrefix(line)
            }
        }
    }

    // MARK: - Inline link / image / footnote

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
            let caret = sel.location + 1 + (text as NSString).length + 2
            applyFormattingEdit(rawRange: sel, replacement: replacement,
                                select: NSRange(location: caret, length: 0))
            return
        }

        // Caret: check if inside an existing link → unwrap it.
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
            let caret = word.location + 1 + (wordText as NSString).length + 2
            applyFormattingEdit(rawRange: word, replacement: replacement,
                                select: NSRange(location: caret, length: 0))
            return
        }

        // No word: insert empty link, caret inside ().
        applyFormattingEdit(rawRange: NSRange(location: sel.location, length: 0),
                            replacement: "[]()",
                            select: NSRange(location: sel.location + 3, length: 0))
    }

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
            let caret = sel.location + 2 + (text as NSString).length + 2
            applyFormattingEdit(rawRange: sel, replacement: replacement,
                                select: NSRange(location: caret, length: 0))
            return
        }

        // Expand to current word.
        if let word = currentWordRange() {
            let wordText = ns.substring(with: word)
            let replacement = "![" + wordText + "]()"
            let caret = word.location + 2 + (wordText as NSString).length + 2
            applyFormattingEdit(rawRange: word, replacement: replacement,
                                select: NSRange(location: caret, length: 0))
            return
        }

        applyFormattingEdit(rawRange: NSRange(location: sel.location, length: 0),
                            replacement: "![]()",
                            select: NSRange(location: sel.location + 4, length: 0))
    }

    /// Footnote (NOT invertible): inserts `[^n]` after the selection/caret (or the
    /// end of the current word when no selection) and appends `[^n]: ` at EOF.
    private func insertFootnote() {
        let ns = rawSource as NSString
        let sel = selectedRange()
        let n = nextFootnoteNumber()

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
        let needsNewline = body.length > 0 && body.character(at: body.length - 1) != 0x0A
        newRaw += (needsNewline ? "\n" : "") + "[^\(n)]: "
        let caret = (newRaw as NSString).length
        applyWholeDocumentEdit(newRawSource: newRaw, select: NSRange(location: caret, length: 0))
    }

    // MARK: - Code block / math block / table

    private func insertCodeBlock() {
        let ctx = selectedLineContext()
        if ctx.lines.count >= 2, ctx.lines.first!.hasPrefix("```"), ctx.lines.last! == "```" {
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
        applyFormattingEdit(rawRange: ctx.range, replacement: replacement,
                            select: NSRange(location: ctx.range.location + 3, length: 0))
    }

    /// Display math block: `$$\n{content}\n$$`. Toggle-off when the selected
    /// lines are already fenced with `$$`.
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

    /// Insert a 3×2 placeholder table with padded dividers (matching header width).
    /// Ignores the selection; not a toggle.
    private func insertTable() {
        let ns = rawSource as NSString
        let sel = selectedRange()
        let line = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        let lineEndsWithNewline = line.upperBound > line.location && ns.character(at: line.upperBound - 1) == 0x0A
        let lineIsBlank = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // 3 columns, dividers padded to match "Header N" length (8 chars).
        let table = """
            | Header 1 | Header 2 | Header 3 |
            | -------- | -------- | -------- |
            | Cell 1 | Cell 2 | Cell 3 |
            | Cell 4 | Cell 5 | Cell 6 |

            """  // trailing newline via the heredoc newline before closing """
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

    // MARK: - Callout / alert

    /// Wrap the selected lines in a callout (`> [!TYPE]` header + `> ` body), or
    /// strip it when the lines are already that callout. `type` is pre-cased.
    func applyCalloutType(_ type: String) {
        transformSelectedLines { lines in
            let header = "> [!\(type)]"
            if let first = lines.first,
               first.trimmingCharacters(in: .whitespaces).lowercased() == "> [!\(type.lowercased())]" {
                // Strip: drop the header, unprefix the body.
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
