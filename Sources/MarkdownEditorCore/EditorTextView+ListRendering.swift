import AppKit

// MARK: - List Rendering
//
// Everything that turns a list item's marker into its rendered form, used by
// the `.listItem` branch of `styleBlock` (in EditorTextView+Rendering.swift):
//
//   - Indentation: `listPadding`, `listParagraphStyle`, `listDepth`. Each
//     nesting level steps in by one marker "slot" so a child's marker lands
//     under its parent's content (Apple Notes style).
//   - Marker icons: `checkboxAttachment` (circle), `bulletAttachment` (dot).
//   - `styleListDelimiter` applies the right treatment per list type when the
//     item is inactive (cursor outside): bullet → dot, checkbox → circle,
//     ordered → dimmed "N." right-aligned into the slot. The leading
//     whitespace is hidden so the indent comes purely from the paragraph style.

extension EditorTextView {

    // MARK: Indentation

    /// Fixed padding before the bullet/number marker for all list items.
    var listPadding: CGFloat { 16 }

    /// Paragraph style for a list item. `firstLineIndent` positions the marker
    /// line; `contentIndent` (the hanging indent) aligns wrapped lines and the
    /// text after the marker.
    func listParagraphStyle(firstLineIndent: CGFloat, contentIndent: CGFloat) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = bodyParagraphStyle.lineSpacing
        ps.paragraphSpacing = bodyParagraphStyle.paragraphSpacing
        ps.firstLineHeadIndent = firstLineIndent
        ps.headIndent = contentIndent
        return ps
    }

    /// Nesting depth of a list item from its leading whitespace, using the
    /// document's detected indent unit (a tab counts as one unit/level).
    func listDepth(leadingWhitespace ws: String) -> Int {
        let unit = max(1, listIndentUnit)
        var cols = 0
        for ch in ws { cols += (ch == "\t") ? unit : 1 }
        return cols / unit
    }

    // MARK: Marker Icons

    /// Creates an NSTextAttachment with a circle icon for checkbox rendering.
    /// Unchecked: gray outlined circle. Checked: filled yellow circle with checkmark.
    private func checkboxAttachment(checked: Bool) -> NSTextAttachment {
        let fontSize = bodyFont.pointSize
        let image = NSImage(size: NSSize(width: fontSize, height: fontSize), flipped: true) { bounds in
            let inset: CGFloat = 1.0
            let circleRect = bounds.insetBy(dx: inset, dy: inset)
            let path = NSBezierPath(ovalIn: circleRect)

            if checked {
                NSColor.systemYellow.setFill()
                path.fill()
                // Checkmark
                let check = NSBezierPath()
                check.lineWidth = max(1.5, fontSize * 0.1)
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                let cx = bounds.midX, cy = bounds.midY
                let r = circleRect.width / 2
                check.move(to: NSPoint(x: cx - r * 0.35, y: cy + r * 0.05))
                check.line(to: NSPoint(x: cx - r * 0.08, y: cy + r * 0.35))
                check.line(to: NSPoint(x: cx + r * 0.38, y: cy - r * 0.30))
                NSColor.white.setStroke()
                check.stroke()
            } else {
                let lw = max(1.5, fontSize * 0.08)
                // Inset the stroke path so its outer edge matches the filled circle's edge.
                let strokeRect = circleRect.insetBy(dx: lw / 2, dy: lw / 2)
                let strokePath = NSBezierPath(ovalIn: strokeRect)
                strokePath.lineWidth = lw
                NSColor.tertiaryLabelColor.setStroke()
                strokePath.stroke()
            }
            return true
        }

        let attachment = NSTextAttachment()
        attachment.image = image
        // Vertically center the circle relative to the text baseline
        attachment.bounds = CGRect(x: 0, y: -fontSize * 0.15,
                                   width: fontSize, height: fontSize)
        return attachment
    }

    /// Creates an attachment with a small filled dot for unordered bullets,
    /// sized to the same box as the checkbox circle so bullet and todo lists
    /// share one indentation (Apple Notes style).
    private func bulletAttachment() -> NSTextAttachment {
        let fontSize = bodyFont.pointSize
        let image = NSImage(size: NSSize(width: fontSize, height: fontSize), flipped: true) { bounds in
            let r = fontSize * 0.13                 // small dot
            let dot = NSRect(x: bounds.midX - r, y: bounds.midY - r, width: 2 * r, height: 2 * r)
            // Match the dim used for numbered-list markers (syntaxDimColor).
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -fontSize * 0.15,
                                   width: fontSize, height: fontSize)
        return attachment
    }

    // MARK: Marker Styling

    /// Applies custom non-active styling to a list item's delimiter range.
    /// - Unordered bullet: small dot attachment.
    /// - Unchecked / checked checkbox: circle icon (Apple Notes style).
    /// - Ordered: dimmed "N." marker.
    /// In all cases the leading whitespace is hidden so the indentation comes
    /// from the paragraph style.
    func styleListDelimiter(
        _ result: NSMutableAttributedString,
        markdown: String,
        delimiterRange dr: NSRange,
        ordered: Bool,
        checkbox: SyntaxHighlighter.Span.Kind.CheckboxState?
    ) {
        if ordered {
            // Ordered lists: hide the leading whitespace (indent comes from the
            // paragraph style) and dim the "N." marker.
            let nsDelim = (markdown as NSString).substring(with: dr) as NSString
            let digit = nsDelim.rangeOfCharacter(from: .decimalDigits)
            let wsLen = digit.location == NSNotFound ? 0 : digit.location
            if wsLen > 0 {
                let before = NSRange(location: dr.location, length: wsLen)
                result.addAttribute(.font, value: hiddenFont, range: before)
                result.addAttribute(.foregroundColor, value: NSColor.clear, range: before)
            }
            let numStart = dr.location + wsLen
            result.addAttribute(.foregroundColor, value: syntaxDimColor,
                                range: NSRange(location: numStart, length: dr.upperBound - numStart))
            return
        }

        if checkbox == nil {
            // Plain bullet: render the dash as a small dot (Apple Notes style),
            // sized to the checkbox box so all list types share one indent.
            let nsDelim = (markdown as NSString).substring(with: dr) as NSString
            let markerRel = nsDelim.rangeOfCharacter(from: CharacterSet(charactersIn: "-*+"))
            guard markerRel.location != NSNotFound else {
                result.addAttribute(.foregroundColor, value: syntaxDimColor, range: dr)
                return
            }
            let markerAbs = dr.location + markerRel.location
            // Hide any leading whitespace before the bullet (matches checkbox).
            if markerRel.location > 0 {
                let before = NSRange(location: dr.location, length: markerRel.location)
                result.addAttribute(.font, value: hiddenFont, range: before)
                result.addAttribute(.foregroundColor, value: NSColor.clear, range: before)
            }
            // Dot attachment on the bullet character.
            result.addAttribute(.attachment, value: bulletAttachment(),
                                range: NSRange(location: markerAbs, length: 1))
            // Dim the trailing space(s) after the bullet.
            let afterStart = markerAbs + 1
            if afterStart < dr.upperBound {
                result.addAttribute(.foregroundColor, value: syntaxDimColor,
                                    range: NSRange(location: afterStart, length: dr.upperBound - afterStart))
            }
            return
        }

        guard let checkbox = checkbox else { return }

        let nsDelim = (markdown as NSString).substring(with: dr) as NSString

        // --- Checkbox item: replace [ ]/[x] with circle icon ---
        let bracketOpen = nsDelim.range(of: "[")
        guard bracketOpen.location != NSNotFound else {
            result.addAttribute(.foregroundColor, value: syntaxDimColor, range: dr)
            return
        }
        let afterOpen = NSRange(location: bracketOpen.upperBound,
                                 length: nsDelim.length - bracketOpen.upperBound)
        let bracketClose = nsDelim.range(of: "]", options: [], range: afterOpen)
        guard bracketClose.location != NSNotFound else {
            result.addAttribute(.foregroundColor, value: syntaxDimColor, range: dr)
            return
        }

        let cbStart = dr.location + bracketOpen.location
        let cbEnd = dr.location + bracketClose.upperBound

        // Hide everything before `[` (the "- " prefix) — zero-width + clear
        if bracketOpen.location > 0 {
            let before = NSRange(location: dr.location, length: bracketOpen.location)
            result.addAttribute(.font, value: hiddenFont, range: before)
            result.addAttribute(.foregroundColor, value: NSColor.clear, range: before)
        }

        // Place circle attachment on `[` character
        let attachment = checkboxAttachment(checked: checkbox == .checked)
        result.addAttribute(.attachment, value: attachment,
                            range: NSRange(location: cbStart, length: 1))

        // Hide remaining checkbox characters (` ]`/`x]`) with zero-width + clear
        let hideStart = cbStart + 1
        if hideStart < cbEnd {
            let hideRange = NSRange(location: hideStart, length: cbEnd - hideStart)
            result.addAttribute(.font, value: hiddenFont, range: hideRange)
            result.addAttribute(.foregroundColor, value: NSColor.clear, range: hideRange)
        }

        // Dim everything after `]` (trailing space)
        if cbEnd < dr.upperBound {
            let after = NSRange(location: cbEnd, length: dr.upperBound - cbEnd)
            result.addAttribute(.foregroundColor, value: syntaxDimColor, range: after)
        }
    }
}
