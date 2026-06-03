import AppKit

// MARK: - Word-Level Styling
//
// All blocks are styled the same way: content gets rich text attributes,
// and inline delimiters are either hidden (cursor elsewhere) or dimmed
// (cursor inside the token). Block-level markers are always dimmed.
//
// The text storage always contains the raw markdown — no string mutation.

extension EditorTextView {

    /// Color for dimmed syntax delimiters (*, **, `, #, etc.)
    var syntaxDimColor: NSColor { .tertiaryLabelColor }

    /// Color for inline code spans.
    var codeColor: NSColor { theme.codeColor }

    /// Monospaced font for tables.
    var tableFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize * 0.9, weight: .regular)
    }

    /// Monospaced font for code blocks.
    var codeBlockFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize * 0.9, weight: .regular)
    }

    /// Font used to visually hide delimiter characters.
    /// Near-zero size makes them effectively invisible and zero-width.
    var hiddenFont: NSFont { NSFont.systemFont(ofSize: 0.01) }

    /// Fixed padding before the bullet/number marker for all list items.
    var listPadding: CGFloat { 16 }

    /// Paragraph style for list items. A fixed padding pushes the marker
    /// away from the left edge. Nesting beyond level 1 comes from raw
    /// whitespace characters (deletable by the user). Wrapped lines use
    /// `headIndent` to align with content after the marker.
    private func listParagraphStyle(markerWidth: CGFloat = 0) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = bodyParagraphStyle.lineSpacing
        ps.paragraphSpacing = bodyParagraphStyle.paragraphSpacing
        ps.firstLineHeadIndent = listPadding
        ps.headIndent = listPadding + markerWidth
        return ps
    }

    /// Monospaced font for inline code spans, same size as body text.
    var inlineCodeFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize * 0.9, weight: .regular)
    }

    /// Subtle background color for inline code spans.
    var inlineCodeBackground: NSColor {
        NSColor(calibratedWhite: 0.5, alpha: 0.1)
    }

    /// Paragraph style for thematic breaks. Uses a DividerTextBlock (1em
    /// height) that draws a centered hairline. paragraphSpacingBefore mirrors
    /// the body style so the gaps above and below the line are symmetric.
    private func thematicBreakParagraphStyle() -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.paragraphSpacingBefore = bodyParagraphStyle.paragraphSpacingBefore
        ps.paragraphSpacing = 0

        let block = DividerTextBlock()
        block.lineHeight = bodyFont.pointSize
        block.setContentWidth(100, type: .percentageValueType)
        ps.textBlocks = [block]

        return ps
    }

    /// Paragraph style with a left border for blockquotes.
    private func blockquoteParagraphStyle() -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = bodyParagraphStyle.lineSpacing
        ps.paragraphSpacing = bodyParagraphStyle.paragraphSpacing

        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)
        let leftEdge = NSRectEdge(rawValue: 0)!
        block.setWidth(2, type: .absoluteValueType, for: .border, edge: leftEdge)
        block.setBorderColor(.tertiaryLabelColor, for: leftEdge)
        ps.textBlocks = [block]

        return ps
    }

    // MARK: - Delimiter Hiding Classification

    /// Returns true if this span kind's delimiters should be hidden (not just
    /// dimmed) when the cursor is not inside the token.
    private func isDelimiterHideable(_ kind: SyntaxHighlighter.Span.Kind) -> Bool {
        switch kind {
        case .bold, .italic, .boldItalic, .strikethrough, .highlight,
             .code, .link, .image, .lineBreak,
             .heading, .blockquote:
            return true
        case .listItem, .table, .codeBlock, .thematicBreak:
            return false
        }
    }

    // MARK: - Checkbox Attachment

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

    // MARK: - List Marker Styling

    /// Applies custom non-active styling to a list item's delimiter range.
    /// - Unordered bullet: dimmed
    /// - Unchecked checkbox: circle icon (Apple Notes style)
    /// - Checked checkbox: filled circle icon (Apple Notes style)
    /// - Ordered: all dimmed
    private func styleListDelimiter(
        _ result: NSMutableAttributedString,
        markdown: String,
        delimiterRange dr: NSRange,
        ordered: Bool,
        checkbox: SyntaxHighlighter.Span.Kind.CheckboxState?
    ) {
        if ordered || checkbox == nil {
            // Ordered lists and plain bullets: dim everything
            result.addAttribute(.foregroundColor, value: syntaxDimColor, range: dr)
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

    // MARK: - Unified Styling

    /// Styles raw markdown text with rich attributes. Inline delimiters are hidden
    /// unless the cursor is inside the token (in which case they're dimmed).
    /// Block-level markers are always dimmed, never hidden.
    ///
    /// - Parameters:
    ///   - markdown: Raw markdown text.
    ///   - cursorPosition: Cursor offset within the markdown (nil = hide all inline delimiters).
    func styleBlock(_ markdown: String, cursorPosition: Int? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString(string: markdown, attributes: baseAttributes)
        guard !markdown.isEmpty else { return result }

        let spans = SyntaxHighlighter.parse(markdown)

        for span in spans {
            let cursorInToken = cursorPosition.map {
                $0 >= span.fullRange.location && $0 <= span.fullRange.upperBound
            } ?? false

            // --- Content styling (applied first) ---
            switch span.kind {
            case .bold:
                guard span.contentRange.upperBound <= result.length else { continue }
                let bold = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
                result.addAttribute(.font, value: bold, range: span.contentRange)

            case .italic:
                guard span.contentRange.upperBound <= result.length else { continue }
                let italic = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
                result.addAttribute(.font, value: italic, range: span.contentRange)

            case .boldItalic:
                guard span.contentRange.upperBound <= result.length else { continue }
                let bi = NSFontManager.shared.convert(bodyFont, toHaveTrait: [.boldFontMask, .italicFontMask])
                result.addAttribute(.font, value: bi, range: span.contentRange)

            case .code:
                guard span.contentRange.upperBound <= result.length else { continue }
                result.addAttribute(.font, value: inlineCodeFont, range: span.contentRange)
                result.addAttribute(.foregroundColor, value: codeColor, range: span.contentRange)
                result.addAttribute(.backgroundColor, value: inlineCodeBackground, range: span.contentRange)

            case .codeBlock:
                guard span.contentRange.upperBound <= result.length else { continue }
                result.addAttribute(.font, value: codeBlockFont, range: span.contentRange)
                result.addAttribute(.foregroundColor, value: codeColor, range: span.contentRange)

            case .strikethrough:
                guard span.contentRange.upperBound <= result.length else { continue }
                result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.contentRange)

            case .highlight:
                guard span.contentRange.upperBound <= result.length else { continue }
                result.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: span.contentRange)

            case .heading(let level):
                guard span.fullRange.upperBound <= result.length else { continue }
                let scale: CGFloat = level == 1 ? 1.5 : level == 2 ? 1.3 : level == 3 ? 1.15 : 1.0
                let sized = NSFont(descriptor: bodyFont.fontDescriptor,
                                   size: bodyFont.pointSize * scale) ?? bodyFont
                let heading = NSFontManager.shared.convert(sized, toHaveTrait: .boldFontMask)
                result.addAttribute(.font, value: heading, range: span.fullRange)

            case .link:
                guard span.contentRange.upperBound <= result.length else { continue }
                result.addAttribute(.foregroundColor, value: accentColor, range: span.contentRange)
                result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: span.contentRange)

            case .image:
                guard span.contentRange.upperBound <= result.length else { continue }
                result.addAttribute(.foregroundColor, value: accentColor, range: span.contentRange)
                let italic = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
                result.addAttribute(.font, value: italic, range: span.contentRange)

            case .blockquote:
                guard span.fullRange.upperBound <= result.length else { continue }
                // Paragraph style must cover fullRange so the first character of each
                // paragraph (the `> ` delimiter) carries the NSTextBlock border.
                // NSTextView uses the paragraph style from the first char of a paragraph.
                result.addAttribute(.paragraphStyle, value: blockquoteParagraphStyle(), range: span.fullRange)
                result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.contentRange)

            case .listItem(let ordered, let checkbox):
                guard span.fullRange.upperBound <= result.length else { continue }
                // Measure marker width (including leading whitespace) for hanging indent.
                // Everything from position 0 to content start is the "marker" area.
                let markerStr = (markdown as NSString).substring(to: span.contentRange.location)
                let markerWidth = (markerStr as NSString).size(withAttributes: [.font: bodyFont]).width
                // Apply paragraph style from position 0 — NSTextView uses the paragraph
                // style from the first character of a paragraph.
                result.addAttribute(.paragraphStyle, value: listParagraphStyle(markerWidth: markerWidth), range: NSRange(location: 0, length: result.length))
                // Strikethrough checked items
                if !ordered, checkbox == .checked {
                    result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.contentRange)
                    result.addAttribute(.foregroundColor, value: syntaxDimColor, range: span.contentRange)
                }

            case .table:
                guard span.fullRange.upperBound <= result.length else { continue }
                result.addAttribute(.font, value: tableFont, range: span.fullRange)
                // Dim all pipe characters
                let nsStr = (result.string as NSString)
                var searchRange = span.fullRange
                while searchRange.length > 0 {
                    let pipeRange = nsStr.range(of: "|", options: [], range: searchRange)
                    guard pipeRange.location != NSNotFound else { break }
                    result.addAttribute(.foregroundColor, value: syntaxDimColor, range: pipeRange)
                    let newStart = pipeRange.upperBound
                    searchRange = NSRange(location: newStart, length: max(0, span.fullRange.upperBound - newStart))
                }

            case .thematicBreak:
                guard span.fullRange.upperBound <= result.length else { continue }
                if cursorInToken {
                    // Active: show raw dashes, dimmed
                    result.addAttribute(.foregroundColor, value: syntaxDimColor, range: span.fullRange)
                } else {
                    // Non-active: horizontal line via NSTextBlock, hide raw text
                    result.addAttribute(.paragraphStyle, value: thematicBreakParagraphStyle(), range: span.fullRange)
                    result.addAttribute(.font, value: hiddenFont, range: span.fullRange)
                    result.addAttribute(.foregroundColor, value: NSColor.clear, range: span.fullRange)
                }

            case .lineBreak:
                break  // Delimiter handling done below
            }

            // --- Delimiter treatment (applied after content styling so it takes precedence) ---
            for dr in span.delimiterRanges {
                guard dr.upperBound <= result.length else { continue }

                if case .thematicBreak = span.kind {
                    // Thematic break: fully handled in content styling above
                    if cursorInToken {
                        result.addAttribute(.foregroundColor, value: syntaxDimColor, range: dr)
                    }
                    // Non-active: already hidden, don't override
                } else if case .listItem(let ordered, let checkbox) = span.kind {
                    // List markers: custom styling when non-active, dimmed when active
                    if cursorInToken {
                        result.addAttribute(.foregroundColor, value: syntaxDimColor, range: dr)
                    } else {
                        styleListDelimiter(result, markdown: markdown,
                                           delimiterRange: dr, ordered: ordered,
                                           checkbox: checkbox)
                    }
                } else if cursorInToken || !isDelimiterHideable(span.kind) {
                    // Visible: dim the delimiters
                    result.addAttribute(.foregroundColor, value: syntaxDimColor, range: dr)
                } else if case .blockquote = span.kind {
                    // Blockquote: invisible but preserve width for indentation
                    result.addAttribute(.foregroundColor, value: NSColor.clear, range: dr)
                } else {
                    // Hidden: make delimiters invisible and near-zero-width
                    result.addAttribute(.font, value: hiddenFont, range: dr)
                    result.addAttribute(.foregroundColor, value: NSColor.clear, range: dr)
                }
            }
        }

        return result
    }

    // MARK: - In-Place Block Restyling

    /// Re-styles a single block in the text storage in place (no string mutation).
    /// `cursorInBlock` is the cursor offset within the block, or nil to hide
    /// all inline delimiters (non-active block).
    func restyleBlock(_ blockIndex: Int, cursorInBlock: Int? = nil) {
        guard let ts = textStorage,
              blockIndex < blocks.count else { return }

        let block = blocks[blockIndex]
        guard block.range.upperBound <= ts.length else { return }

        let styled = styleBlock(block.content, cursorPosition: cursorInBlock)
        let offset = block.range.location

        styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length), options: []) { attrs, range, _ in
            let tsRange = NSRange(location: range.location + offset, length: range.length)
            ts.setAttributes(attrs, range: tsRange)
        }
    }

    /// Re-applies styling to the active block. Called after each keystroke.
    func applyBlockStyle() {
        guard let ts = textStorage,
              let activeIdx = activeBlockIndex,
              activeIdx < blocks.count else { return }

        let cursorInBlock = max(0, selectedRange().location - blocks[activeIdx].range.location)

        isUpdating = true
        ts.beginEditing()
        restyleBlock(activeIdx, cursorInBlock: cursorInBlock)
        ts.endEditing()
        isUpdating = false

        typingAttributes = baseAttributes
    }
}

// MARK: - DividerTextBlock

/// NSTextBlock subclass that renders a full-width horizontal hairline
/// centered vertically within a block whose height matches body text.
private class DividerTextBlock: NSTextBlock {

    /// Target block height (set to bodyFont.pointSize by the caller).
    var lineHeight: CGFloat = 16

    override func rectForLayout(
        at startingPosition: CGPoint,
        in rect: NSRect,
        textContainer: NSTextContainer,
        characterRange charRange: NSRange
    ) -> NSRect {
        var r = super.rectForLayout(at: startingPosition, in: rect,
                                    textContainer: textContainer,
                                    characterRange: charRange)
        r.size.height = lineHeight
        return r
    }

    override func drawBackground(
        withFrame frameRect: NSRect,
        in controlView: NSView,
        characterRange charRange: NSRange,
        layoutManager: NSLayoutManager
    ) {
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        let y = round(frameRect.midY) + 0.5
        path.move(to: NSPoint(x: frameRect.minX, y: y))
        path.line(to: NSPoint(x: frameRect.maxX, y: y))
        path.lineWidth = 1
        path.stroke()
    }
}
