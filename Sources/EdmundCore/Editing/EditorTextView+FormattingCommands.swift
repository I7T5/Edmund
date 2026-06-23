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

    @objc public func formatWikilink(_ sender: Any?)      { toggleInlineWrap(open: "[[", close: "]]") }
    @objc public func formatLink(_ sender: Any?)          { insertLink() }
    @objc public func formatImage(_ sender: Any?)         { insertImage() }
    @objc public func formatFootnote(_ sender: Any?)      { insertFootnote() }

    // MARK: Blocks

    @objc public func formatBulletedList(_ sender: Any?)  { toggleLinePrefix("- ") }
    @objc public func formatNumberedList(_ sender: Any?)  { toggleNumberedList() }
    @objc public func formatChecklist(_ sender: Any?)     { toggleChecklist() }
    @objc public func formatBlockQuote(_ sender: Any?)    { toggleLinePrefix("> ") }
    @objc public func formatCodeBlock(_ sender: Any?)     { insertCodeBlock() }
    @objc public func formatMathBlock(_ sender: Any?)     { toggleInlineWrap(open: "$$", close: "$$") }
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

    /// Prepend `prefix` to every line, or strip it when every non-empty line
    /// already has it (toggle). Used for `- ` bullets and `> ` block quotes.
    func toggleLinePrefix(_ prefix: String) {
        transformSelectedLines { lines in
            let nonEmpty = lines.filter { !$0.isEmpty }
            let stripAll = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.hasPrefix(prefix) }
            if stripAll {
                return lines.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
            }
            if lines == [""] { return [prefix] }     // caret on a blank line → start one
            return lines.map { $0.isEmpty ? $0 : prefix + $0 }
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
                return lines.map { self.stripLeadingNumber($0) }
            }
            if lines == [""] { return ["\(start). "] }
            var n = start
            return lines.map { line -> String in
                guard !line.isEmpty else { return line }
                defer { n += 1 }
                return "\(n). " + line
            }
        }
    }

    /// Checklist (NOT invertible): non-checklist lines gain `- [ ] `; existing
    /// checklist lines toggle their mark `[ ]` ↔ `[x]`.
    func toggleChecklist() {
        transformSelectedLines { lines in
            lines.map { line in
                let ns = line as NSString
                // "- [ ] " or "- [x] " — mark is at offset 3, closing "] " at 4–5.
                if ns.length >= 6,
                   ns.substring(to: 3) == "- [",
                   ns.substring(with: NSRange(location: 4, length: 2)) == "] " {
                    let mark = ns.character(at: 3)
                    let newMark = (mark == 0x20) ? "x" : " "   // ' ' ↔ 'x'
                    return "- [" + newMark + "] " + ns.substring(from: 6)
                }
                return "- [ ] " + line
            }
        }
    }

    // MARK: - Inline link / image / footnote

    private func insertLink() {
        let ns = rawSource as NSString
        let sel = selectedRange()
        if sel.length > 0 {
            let text = ns.substring(with: sel)
            if let inner = unwrapLink(text) {     // toggle off
                applyFormattingEdit(rawRange: sel, replacement: inner,
                                    select: NSRange(location: sel.location, length: (inner as NSString).length))
                return
            }
            let replacement = "[" + text + "]()"
            let caret = sel.location + 1 + (text as NSString).length + 2   // inside ()
            applyFormattingEdit(rawRange: sel, replacement: replacement,
                                select: NSRange(location: caret, length: 0))
        } else {
            applyFormattingEdit(rawRange: NSRange(location: sel.location, length: 0),
                                replacement: "[]()",
                                select: NSRange(location: sel.location + 3, length: 0))  // inside ()
        }
    }

    private func insertImage() {
        let ns = rawSource as NSString
        let sel = selectedRange()
        if sel.length > 0 {
            let text = ns.substring(with: sel)
            if let inner = unwrapImage(text) {    // toggle off
                applyFormattingEdit(rawRange: sel, replacement: inner,
                                    select: NSRange(location: sel.location, length: (inner as NSString).length))
                return
            }
            let replacement = "![" + text + "]()"
            let caret = sel.location + 2 + (text as NSString).length + 2  // inside ()
            applyFormattingEdit(rawRange: sel, replacement: replacement,
                                select: NSRange(location: caret, length: 0))
        } else {
            applyFormattingEdit(rawRange: NSRange(location: sel.location, length: 0),
                                replacement: "![]()",
                                select: NSRange(location: sel.location + 4, length: 0))  // inside ()
        }
    }

    /// Footnote (NOT invertible): insert `[^n]` after the selection/caret and a
    /// `[^n]: ` definition at the bottom of the file; the caret lands at the
    /// definition so the note can be typed.
    private func insertFootnote() {
        let ns = rawSource as NSString
        let sel = selectedRange()
        let n = nextFootnoteNumber()
        let markerPos = sel.length > 0 ? sel.upperBound : sel.location

        var newRaw = ns.replacingCharacters(in: NSRange(location: markerPos, length: 0),
                                            with: "[^\(n)]")
        let body = newRaw as NSString
        let needsNewline = body.length > 0 && body.character(at: body.length - 1) != 0x0A
        newRaw += (needsNewline ? "\n" : "") + "[^\(n)]: "
        let caret = (newRaw as NSString).length
        applyWholeDocumentEdit(newRawSource: newRaw, select: NSRange(location: caret, length: 0))
    }

    // MARK: - Code block / table

    private func insertCodeBlock() {
        let ctx = selectedLineContext()
        // Toggle off when the selected lines are already a full fence.
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
        // Caret on the opening-fence info line, right after "```".
        applyFormattingEdit(rawRange: ctx.range, replacement: replacement,
                            select: NSRange(location: ctx.range.location + 3, length: 0))
    }

    /// Insert a 2×2 placeholder table on its own line after the caret's line.
    /// Ignores the selection; not a toggle.
    private func insertTable() {
        let ns = rawSource as NSString
        let sel = selectedRange()
        let line = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        let lineEndsWithNewline = line.upperBound > line.location && ns.character(at: line.upperBound - 1) == 0x0A
        let lineIsBlank = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let table = "| Header 1 | Header 2 |\n| --- | --- |\n| Cell 1 | Cell 2 |\n"
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
        // Caret at the first header cell ("Header 1"), i.e. past the leading
        // newline (if any) and "| ".
        let caret = insertPos + lead + 2
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
