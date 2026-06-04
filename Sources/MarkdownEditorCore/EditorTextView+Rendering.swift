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

    /// Paragraph style for thematic breaks. Uses a ThematicBreakTextBlock (1em
    /// height) that draws a centered hairline. paragraphSpacingBefore mirrors
    /// the body style so the gaps above and below the line are symmetric.
    private func thematicBreakParagraphStyle() -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.paragraphSpacingBefore = bodyParagraphStyle.paragraphSpacingBefore
        ps.paragraphSpacing = 0

        let block = ThematicBreakTextBlock()
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
                // Measure marker width for hanging indent. For checkbox items,
                // measure the VISUAL width (hidden prefix + circle attachment),
                // not the raw text width.
                let markerStr = (markdown as NSString).substring(to: span.contentRange.location)
                let markerWidth: CGFloat
                if checkbox != nil {
                    let leadingWS = markerStr.prefix(while: { $0 == " " || $0 == "\t" })
                    let wsWidth = (String(leadingWS) as NSString).size(withAttributes: [.font: bodyFont]).width
                    let spaceWidth = (" " as NSString).size(withAttributes: [.font: bodyFont]).width
                    markerWidth = wsWidth + bodyFont.pointSize + spaceWidth
                } else {
                    markerWidth = (markerStr as NSString).size(withAttributes: [.font: bodyFont]).width
                }
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
                if cursorInToken {
                    // Active: monospace, all pipes dimmed
                    result.addAttribute(.font, value: tableFont, range: span.fullRange)
                    let nsStr = (result.string as NSString)
                    var sr = span.fullRange
                    while sr.length > 0 {
                        let pr = nsStr.range(of: "|", options: [], range: sr)
                        guard pr.location != NSNotFound else { break }
                        result.addAttribute(.foregroundColor, value: syntaxDimColor, range: pr)
                        let ns = pr.upperBound
                        sr = NSRange(location: ns, length: max(0, span.fullRange.upperBound - ns))
                    }
                } else {
                    // Non-active: bold header, hidden pipes, column-width alignment
                    // via kern, drawn vertical + horizontal borders via TableRowTextBlock,
                    // with cell padding for breathing room.
                    let tableNS = (result.string as NSString)
                    let tableStr = tableNS.substring(with: span.fullRange)
                    let lines = tableStr.components(separatedBy: "\n")

                    let boldFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
                    let cellHPad = bodyFont.pointSize * 0.3
                    let cellVPad = bodyFont.pointSize * 0.15

                    // --- Compute column widths (max cell width + horizontal padding) ---
                    let headerCells = splitTableRow(lines[0])
                    let numCols = headerCells.count
                    guard numCols > 0 else { break }
                    var colWidths = [CGFloat](repeating: 0, count: numCols)
                    for (li, line) in lines.enumerated() {
                        guard li != 1 else { continue }
                        let cells = splitTableRow(line)
                        let f: NSFont = (li == 0) ? boldFont : bodyFont
                        for ci in 0..<min(cells.count, numCols) {
                            let w = (cells[ci] as NSString).size(withAttributes: [.font: f]).width
                            colWidths[ci] = max(colWidths[ci], w)
                        }
                    }
                    // Add horizontal padding to each column (space after cell text).
                    for ci in 0..<numCols {
                        colWidths[ci] += 2 * cellHPad
                    }

                    // Column-border X offsets (between columns) and total width.
                    var borderXOffsets: [CGFloat] = []
                    var cumX: CGFloat = 0
                    for ci in 0..<numCols {
                        cumX += colWidths[ci]
                        if ci < numCols - 1 { borderXOffsets.append(cumX) }
                    }
                    let totalWidth = cumX

                    let leftEdge  = NSRectEdge(rawValue: 0)!
                    let rightEdge = NSRectEdge(rawValue: 2)!
                    let edge1     = NSRectEdge(rawValue: 1)!
                    let edge3     = NSRectEdge(rawValue: 3)!

                    // --- Style each row ---
                    var lineOffset = span.fullRange.location
                    for (i, line) in lines.enumerated() {
                        let lineLen = (line as NSString).length
                        let lineRange = NSRange(location: lineOffset, length: lineLen)
                        guard lineRange.upperBound <= result.length else { break }

                        let rowFont: NSFont = (i == 0) ? boldFont : bodyFont

                        // Paragraph style with TableRowTextBlock for borders
                        let ps = NSMutableParagraphStyle()
                        ps.paragraphSpacingBefore = (i == 0)
                            ? bodyParagraphStyle.paragraphSpacingBefore : 0
                        ps.paragraphSpacing = 0
                        ps.lineSpacing = 0
                        let block = TableRowTextBlock()
                        block.verticalLineXOffsets = borderXOffsets
                        block.contentLeftOffset = cellHPad
                        block.setContentWidth(totalWidth, type: .absoluteValueType)
                        // Left/right padding so text doesn't touch the table edge.
                        block.setWidth(cellHPad, type: .absoluteValueType, for: .padding, edge: leftEdge)
                        block.setWidth(cellHPad, type: .absoluteValueType, for: .padding, edge: rightEdge)
                        // Vertical padding for breathing room between rows.
                        block.setWidth(cellVPad, type: .absoluteValueType, for: .padding, edge: edge1)
                        block.setWidth(cellVPad, type: .absoluteValueType, for: .padding, edge: edge3)
                        if i == 1 {
                            block.drawHorizontalLine = true
                            block.heightOverride = 4
                            // Separator needs no vertical padding.
                            block.setWidth(0, type: .absoluteValueType, for: .padding, edge: edge1)
                            block.setWidth(0, type: .absoluteValueType, for: .padding, edge: edge3)
                        }
                        ps.textBlocks = [block]
                        result.addAttribute(.paragraphStyle, value: ps, range: lineRange)

                        if i == 0 {
                            result.addAttribute(.font, value: boldFont, range: lineRange)
                        }

                        if i == 1 {
                            // Separator row: hide all text
                            result.addAttribute(.font, value: hiddenFont, range: lineRange)
                            result.addAttribute(.foregroundColor, value: NSColor.clear, range: lineRange)
                        }

                        // Hide all pipes (zero-width + clear)
                        let lineNS = line as NSString
                        for ci in 0..<lineNS.length {
                            if lineNS.character(at: ci) == 0x7C {
                                let pipeRange = NSRange(location: lineOffset + ci, length: 1)
                                result.addAttribute(.font, value: hiddenFont, range: pipeRange)
                                result.addAttribute(.foregroundColor, value: NSColor.clear, range: pipeRange)
                            }
                        }

                        // Kern-pad each cell to its column width (skip separator)
                        if i != 1 {
                            let ranges = cellRanges(in: lineNS)
                            for ci in 0..<min(ranges.count, numCols) {
                                let cr = ranges[ci]
                                let cellText = lineNS.substring(with: NSRange(location: cr.start, length: cr.end - cr.start))
                                let cellWidth = (cellText as NSString).size(withAttributes: [.font: rowFont]).width
                                let padding = colWidths[ci] - cellWidth
                                if padding > 0.5 {
                                    let kernLoc = lineOffset + cr.end - 1
                                    result.addAttribute(.kern, value: padding, range: NSRange(location: kernLoc, length: 1))
                                }
                            }
                        }

                        lineOffset += lineLen + 1
                    }
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
                } else if case .table = span.kind {
                    // Table delimiters (separator row): dimmed when active, hidden when not
                    if cursorInToken {
                        result.addAttribute(.foregroundColor, value: syntaxDimColor, range: dr)
                    }
                    // Non-active: already hidden by content styling, don't override
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

// MARK: - ThematicBreakTextBlock

/// NSTextBlock subclass that renders a full-width horizontal hairline
/// centered vertically within a block whose height matches body text.
private class ThematicBreakTextBlock: NSTextBlock {

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

// MARK: - TableRowTextBlock

/// NSTextBlock subclass for table rows. Each row draws vertical border lines
/// at column boundaries. The separator row also draws a horizontal hairline.
/// All rows use the same column offsets so the vertical lines align into
/// continuous column borders.
private class TableRowTextBlock: NSTextBlock {

    /// X offsets (from content area left edge) where vertical border lines are drawn.
    var verticalLineXOffsets: [CGFloat] = []

    /// Offset from frameRect.minX to the content area (= left padding).
    var contentLeftOffset: CGFloat = 0

    /// Whether to draw a horizontal hairline centered in the row (separator).
    var drawHorizontalLine = false

    /// Height override for the separator row (collapses to thin strip).
    var heightOverride: CGFloat?

    override func rectForLayout(
        at startingPosition: CGPoint,
        in rect: NSRect,
        textContainer: NSTextContainer,
        characterRange charRange: NSRange
    ) -> NSRect {
        var r = super.rectForLayout(at: startingPosition, in: rect,
                                    textContainer: textContainer,
                                    characterRange: charRange)
        if let h = heightOverride {
            r.size.height = h
        }
        return r
    }

    override func drawBackground(
        withFrame frameRect: NSRect,
        in controlView: NSView,
        characterRange charRange: NSRange,
        layoutManager: NSLayoutManager
    ) {
        NSColor.separatorColor.setStroke()
        let baseX = frameRect.minX + contentLeftOffset

        // Vertical borders at column boundaries
        for xOffset in verticalLineXOffsets {
            let path = NSBezierPath()
            let x = round(baseX + xOffset) + 0.5
            path.move(to: NSPoint(x: x, y: frameRect.minY))
            path.line(to: NSPoint(x: x, y: frameRect.maxY))
            path.lineWidth = 1
            path.stroke()
        }

        // Horizontal separator
        if drawHorizontalLine {
            let path = NSBezierPath()
            let y = round(frameRect.midY) + 0.5
            path.move(to: NSPoint(x: frameRect.minX, y: y))
            path.line(to: NSPoint(x: frameRect.maxX, y: y))
            path.lineWidth = 1
            path.stroke()
        }
    }
}

// MARK: - Table Helpers

/// Splits a markdown table row into cell strings (text between pipes).
/// Handles both `| A | B |` (outer pipes) and `A | B` (no outer pipes).
private func splitTableRow(_ line: String) -> [String] {
    var parts = line.components(separatedBy: "|")
    // Remove empty/whitespace-only first/last from outer pipes.
    if let first = parts.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
        parts.removeFirst()
    }
    if let last = parts.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        parts.removeLast()
    }
    return parts
}

/// Returns `(start, end)` character ranges for each cell in a table line.
/// Works with or without outer pipes. `start` is the first content char,
/// `end` is one past the last content char (i.e., the next pipe or line end).
private func cellRanges(in line: NSString) -> [(start: Int, end: Int)] {
    var pipePos: [Int] = []
    for ci in 0..<line.length {
        if line.character(at: ci) == 0x7C { pipePos.append(ci) }
    }
    guard !pipePos.isEmpty else { return [] }

    // Build edge list: either the pipe position or a virtual -1/length sentinel.
    var edges: [Int] = []
    if pipePos[0] == 0 {
        edges.append(contentsOf: pipePos)
    } else {
        edges.append(-1)
        edges.append(contentsOf: pipePos)
    }
    if pipePos.last != line.length - 1 {
        edges.append(line.length)
    }

    var result: [(start: Int, end: Int)] = []
    for ei in 0..<(edges.count - 1) {
        let s = edges[ei] + 1
        let e = edges[ei + 1]
        if e > s { result.append((s, e)) }
    }
    return result
}
