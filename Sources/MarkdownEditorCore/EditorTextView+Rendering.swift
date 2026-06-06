import AppKit

extension NSAttributedString.Key {
    /// Stores a link's destination (URL string) on its visible text so a
    /// cmd+click can follow it. Kept separate from the system `.link` attribute
    /// to avoid NSTextView's built-in link styling/cursor behavior.
    static let editorLinkURL = NSAttributedString.Key("EditorLinkURL")
}

// MARK: - Word-Level Styling
//
// This file is the heart of the inline live preview. `styleBlock` takes one
// block's raw markdown, parses it into spans (SyntaxHighlighter), and returns
// an NSAttributedString that decorates the *same* characters — the text storage
// always holds the raw markdown, never a stripped version. Formatting is purely
// attribute-based:
//
//   - Content gets rich styling (bold/italic, code color, heading size, …).
//   - Inline delimiters (`**`, `*`, `` ` ``, `$`) are hidden when the cursor is
//     outside the token (near-zero font + clear color) and dimmed when inside.
//   - Block markers (`#`, `>`, list bullets) are decorated or dimmed, never
//     stripped, so editing stays WYSIWYG-ish and round-trips losslessly.
//
// Larger, self-contained pieces live in sibling files to keep this one focused:
//   - EditorTextView+ListRendering.swift  — list/checkbox/bullet markers + indent
//   - EditorTextView+TableSupport.swift   — table border blocks + row parsing
//   - EditorTextView+MathRendering.swift  — `$…$` / `$$…$$` rendering + raw coloring
//
// What remains here: the styling primitives (fonts/colors/paragraph styles),
// the `styleBlock` switch that dispatches per span kind, and the in-place
// `restyleBlock` / `applyBlockStyle` used to re-style a single block on edits.

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

    /// Monospaced font for inline code spans, same size as body text.
    var inlineCodeFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize * 0.9, weight: .regular)
    }

    /// Subtle background color for inline code spans.
    var inlineCodeBackground: NSColor {
        NSColor(calibratedWhite: 0.5, alpha: 0.1)
    }

    /// Paragraph style for thematic breaks. The raw dashes are hidden with a
    /// near-zero font, which would collapse the line — so we force the line to a
    /// full body-line height and add symmetric breathing space above and below.
    /// A ThematicBreakTextBlock draws the hairline centered in that height.
    private func thematicBreakParagraphStyle() -> NSParagraphStyle {
        let lineHeight = bodyFont.pointSize + theme.lineSpacing

        let ps = NSMutableParagraphStyle()
        // Force a real line height despite the hidden (0.01pt) dashes.
        ps.minimumLineHeight = lineHeight
        ps.maximumLineHeight = lineHeight
        // Breathing space above and below — slightly less below, since the line
        // height already contributes space beneath the centered rule.
        ps.paragraphSpacingBefore = bodyFont.pointSize * 0.5
        ps.paragraphSpacing = bodyFont.pointSize * 0.3

        let block = ThematicBreakTextBlock()
        block.lineHeight = lineHeight
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
        case .math(let display):
            // Inline math hides its `$` like other inline tokens; display math
            // is block-level and handled specially.
            return !display
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

            case .link(let destination):
                guard span.contentRange.upperBound <= result.length else { continue }
                result.addAttribute(.foregroundColor, value: accentColor, range: span.contentRange)
                result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: span.contentRange)
                if !destination.isEmpty {
                    result.addAttribute(.editorLinkURL, value: destination, range: span.contentRange)
                }

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
                // Indentation model (Apple Notes style): each nesting level steps
                // in by one marker "slot" (pointSize-wide icon + a space), so a
                // child's marker lands under its parent's content. All list types
                // share the same slot, so their text lines up. The leading
                // whitespace is hidden (by the delimiter styling) and the indent
                // comes entirely from the paragraph style.
                let markerStr = (markdown as NSString).substring(to: span.contentRange.location)
                let leadingWS = markerStr.prefix(while: { $0 == " " || $0 == "\t" })
                let spaceWidth = (" " as NSString).size(withAttributes: [.font: bodyFont]).width
                let slotWidth = bodyFont.pointSize + spaceWidth
                let firstLineIndent: CGFloat
                let contentIndent: CGFloat
                if cursorInToken {
                    // Active (editing): show raw; let the leading whitespace
                    // provide the indent so the source reads naturally.
                    firstLineIndent = listPadding
                    contentIndent = listPadding
                } else {
                    let depth = listDepth(leadingWhitespace: String(leadingWS))
                    let markerStart = listPadding + CGFloat(depth) * slotWidth
                    contentIndent = markerStart + slotWidth
                    if ordered {
                        // Right-align the "N." into the slot so its content lands
                        // at contentIndent (also aligns multi-digit numbers).
                        let numText = String(markerStr.dropFirst(leadingWS.count))
                        let numWidth = (numText as NSString).size(withAttributes: [.font: bodyFont]).width
                        firstLineIndent = max(2, contentIndent - numWidth)
                    } else {
                        firstLineIndent = markerStart
                    }
                    // Hide the leading indentation — the indent is provided entirely
                    // by the paragraph style. swift-markdown's list-item delimiter
                    // range starts at the marker and excludes this whitespace, so
                    // without hiding it here those spaces render visibly and push the
                    // first line right, breaking its alignment with the hanging
                    // (wrapped-line) indent. (The deep-indent rescue parser already
                    // includes the whitespace in its delimiter, so this is a no-op
                    // there.)
                    let wsLen = leadingWS.count
                    if wsLen > 0 {
                        let lead = NSRange(location: 0, length: wsLen)
                        result.addAttribute(.font, value: hiddenFont, range: lead)
                        result.addAttribute(.foregroundColor, value: NSColor.clear, range: lead)
                    }
                }
                // Apply paragraph style from position 0 — NSTextView uses the paragraph
                // style from the first character of a paragraph.
                result.addAttribute(.paragraphStyle,
                                    value: listParagraphStyle(firstLineIndent: firstLineIndent, contentIndent: contentIndent),
                                    range: NSRange(location: 0, length: result.length))
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
                    // Each border is drawn cellHPad before the column boundary
                    // so the 2*cellHPad per column splits evenly: hPad of right
                    // padding for the current cell, hPad of left padding for the next.
                    var borderXOffsets: [CGFloat] = []
                    var cumX: CGFloat = 0
                    for ci in 0..<numCols {
                        cumX += colWidths[ci]
                        if ci < numCols - 1 { borderXOffsets.append(cumX - cellHPad) }
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

            case .math(let display):
                guard span.fullRange.upperBound <= result.length else { continue }
                if cursorInToken {
                    // Active: show the raw LaTeX in monospace (like inline code),
                    // with LaTeX syntax coloring; `$` delimiters dimmed below.
                    result.addAttribute(.font, value: inlineCodeFont, range: span.fullRange)
                    colorMathSource(result, range: span.contentRange)
                } else {
                    let latex = (markdown as NSString).substring(with: span.contentRange)
                    // Size the math to the font already applied at this location, so
                    // inline math inside a heading matches the heading's size.
                    let contextFont = result.attribute(.font, at: span.fullRange.location,
                                                       effectiveRange: nil) as? NSFont ?? bodyFont
                    if let attachment = mathAttachment(latex: latex.trimmingCharacters(in: .whitespacesAndNewlines),
                                                       display: display,
                                                       fontSize: contextFont.pointSize) {
                        // Show the rendered image on the first `$` (which the
                        // attachment replaces) and hide everything after it — the
                        // rest of the opening delimiter, the source, and the close.
                        let hideStart = span.fullRange.location + 1
                        let hideLen = span.fullRange.upperBound - hideStart
                        let hideRange = NSRange(location: hideStart, length: hideLen)
                        result.addAttribute(.font, value: hiddenFont, range: hideRange)
                        result.addAttribute(.foregroundColor, value: NSColor.clear, range: hideRange)
                        result.addAttribute(.attachment, value: attachment,
                                            range: NSRange(location: span.fullRange.location, length: 1))
                        // Display math sits centered on its own line, with
                        // vertical padding on the (first) line that carries the
                        // attachment image.
                        if display {
                            let fullStr = result.string as NSString
                            result.addAttribute(.paragraphStyle,
                                                value: displayMathParagraphStyle(padded: false),
                                                range: span.fullRange)
                            let nl = fullStr.range(of: "\n", options: [], range: span.fullRange)
                            let firstLine = nl.location == NSNotFound
                                ? span.fullRange
                                : NSRange(location: span.fullRange.location,
                                          length: nl.location - span.fullRange.location + 1)
                            result.addAttribute(.paragraphStyle,
                                                value: displayMathParagraphStyle(padded: true),
                                                range: firstLine)
                        }
                    } else {
                        // Invalid LaTeX: surface the raw source in monospace, tinted.
                        result.addAttribute(.font, value: inlineCodeFont, range: span.fullRange)
                        result.addAttribute(.foregroundColor, value: NSColor.systemRed, range: span.fullRange)
                    }
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
                } else if case .math = span.kind {
                    // Math: when active, dim the `$`; when not, the attachment and
                    // source-hiding are already applied in content styling — leave them.
                    if cursorInToken {
                        result.addAttribute(.foregroundColor, value: syntaxDimColor, range: dr)
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

