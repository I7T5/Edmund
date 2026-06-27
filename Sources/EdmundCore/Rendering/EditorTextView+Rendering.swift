import AppKit

extension NSAttributedString.Key {
    /// Stores a link's destination (URL string) on its visible text so a
    /// cmd+click can follow it. Kept separate from the system `.link` attribute
    /// to avoid NSTextView's built-in link styling/cursor behavior.
    static let editorLinkURL = NSAttributedString.Key("EditorLinkURL")
    /// Stores a wikilink's raw `path#heading` target on its visible text so a
    /// cmd+click can resolve it to a file or in-document heading.
    static let editorWikiTarget = NSAttributedString.Key("EditorWikiTarget")
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
//   - EditorTextView+ListMarkerRendering.swift — the `.listItem` styling case
//   - EditorTextView+TableRendering.swift      — the `.table` styling case
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

    /// Color for links and wikilinks — always the theme's accent blue, independent of
    /// the system accent so links stay consistently blue across user accent preferences.
    var linkColor: NSColor { theme.accentColor }

    /// Monospaced font for tables.
    var tableFont: NSFont { theme.monospaceFont() }

    /// Monospaced font for code blocks.
    var codeBlockFont: NSFont { theme.monospaceFont() }

    /// Font used to visually hide delimiter characters.
    /// Near-zero size makes them effectively invisible and zero-width.
    var hiddenFont: NSFont { NSFont.systemFont(ofSize: 0.01) }

    /// Monospaced font for inline code spans.
    var inlineCodeFont: NSFont { theme.monospaceFont() }

    /// Subtle background color for inline code spans.
    var inlineCodeBackground: NSColor {
        NSColor(calibratedWhite: 0.5, alpha: 0.1)
    }

    /// Paragraph style for thematic breaks. The raw dashes are hidden with a
    /// near-zero font, which would collapse the line — so we force the line to a
    /// full body-line height and add symmetric breathing space above and below.
    /// A `.horizontalRule` BlockDecoration draws the hairline centered in it.
    private func thematicBreakParagraphStyle() -> NSParagraphStyle {
        let lineHeight = bodyFont.pointSize + theme.lineSpacing

        let ps = NSMutableParagraphStyle()
        // Force a real line height despite the hidden (0.01pt) dashes.
        ps.minimumLineHeight = lineHeight
        ps.maximumLineHeight = lineHeight
        // Symmetric breathing space. The rule is drawn centered in the
        // fragment, so paragraphSpacingBefore sits above the line (and the
        // rule) while paragraphSpacing sits below — equal values keep the
        // rule visually equidistant from the text on either side. Kept small so
        // the break occupies roughly a body line plus a little air, not a full
        // blank line above and below.
        let pad = bodyFont.pointSize * 0.2
        ps.paragraphSpacingBefore = pad
        ps.paragraphSpacing = pad
        return ps
    }

    /// How far below the rule fragment's geometric center to draw the hairline.
    /// Adjacent text sits at its baseline (low in its line box), so a
    /// center-drawn rule looks too close to the line above; this nudge brings
    /// it down to the optical midpoint between the surrounding text. Tuned
    /// against rendered output (see RenderingRegressionTests / screencapture).
    var thematicBreakCenterOffset: CGFloat { bodyFont.pointSize * 0.3 }

    /// Width of the `> ` quote marker in body text. Used as the hanging indent
    /// for blockquotes and callouts so wrapped/continuation lines align after
    /// the marker (like list items) rather than under the `>`. The marker is
    /// rendered width-preserved (clear when inactive, dimmed when active) on
    /// each line's first visual line, so subsequent lines hang by this width.
    var quoteMarkerWidth: CGFloat {
        ("> " as NSString).size(withAttributes: [.font: bodyFont]).width
    }

    /// Paragraph style for blockquotes: a 2pt text inset matching the width of
    /// the left bar that the `.leftBar` BlockDecoration draws, plus a hanging
    /// indent so wrapped lines align after the `> ` marker.
    private func blockquoteParagraphStyle() -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = bodyParagraphStyle.lineSpacing
        ps.paragraphSpacing = bodyParagraphStyle.paragraphSpacing
        ps.firstLineHeadIndent = 2
        ps.headIndent = 2 + quoteMarkerWidth
        return ps
    }

    // MARK: - Delimiter Hiding Classification

    /// Returns true if this span kind's delimiters should be hidden (not just
    /// dimmed) when the cursor is not inside the token.
    private func isDelimiterHideable(_ kind: SyntaxHighlighter.Span.Kind) -> Bool {
        switch kind {
        case .bold, .italic, .boldItalic, .strikethrough, .highlight,
             .code, .link, .image, .lineBreak,
             .heading, .blockquote, .footnoteReference, .escape:
            return true
        case .listItem, .table, .codeBlock, .thematicBreak, .footnoteDefinition, .comment,
             .htmlTag, .htmlFormat:
            // htmlTag: always colored source (brackets dimmed by the generic
            // pass). htmlFormat: handled explicitly in the delimiter loop.
            return false
        case .wikilink:
            // The `[[`, optional `target|`, and `]]` are hidden when rendered,
            // dimmed when the cursor is inside (like other inline delimiters).
            return true
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
    func styleBlock(_ markdown: String, cursorPosition: Int? = nil,
                    hideComments: Bool = false) -> NSAttributedString {
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
                result.addAttribute(.foregroundColor, value: foregroundColor, range: span.contentRange)
                result.addAttribute(.backgroundColor, value: inlineCodeBackground, range: span.contentRange)

            case .codeBlock(let language):
                guard span.contentRange.upperBound <= result.length else { continue }
                result.addAttribute(.font, value: codeBlockFont, range: span.contentRange)
                highlightCodeBlock(result, contentRange: span.contentRange, language: language)

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
                result.addAttribute(.foregroundColor, value: linkColor, range: span.contentRange)
                result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: span.contentRange)
                if !destination.isEmpty {
                    result.addAttribute(.editorLinkURL, value: destination, range: span.contentRange)
                }

            case .wikilink(let target):
                guard span.contentRange.upperBound <= result.length else { continue }
                // The display text reads as a link; the brackets (and a
                // `target|` alias prefix) are hidden/dimmed by the delimiter pass.
                result.addAttribute(.foregroundColor, value: linkColor, range: span.contentRange)
                result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                    range: span.contentRange)
                if !target.isEmpty {
                    result.addAttribute(.editorWikiTarget, value: target, range: span.contentRange)
                }

            case .image(let destination):
                guard span.fullRange.upperBound <= result.length else { continue }
                if !cursorInToken, let overlay = imageOverlay(destination: destination) {
                    // Rendered: draw the image at the leading `!` and hide the
                    // rest of the `![alt](path)` markdown, reserving the line
                    // height so the picture has room.
                    let hideStart = span.fullRange.location + 1
                    let hideLen = span.fullRange.upperBound - hideStart
                    if hideLen > 0 {
                        let hideRange = NSRange(location: hideStart, length: hideLen)
                        result.addAttribute(.font, value: hiddenFont, range: hideRange)
                        result.addAttribute(.foregroundColor, value: NSColor.clear, range: hideRange)
                    }
                    applyOverlay(overlay,
                                 anchor: NSRange(location: span.fullRange.location, length: 1),
                                 in: result)
                    reserveLineHeight(overlay.bounds.height,
                                      forOverlayAt: span.fullRange.location, in: result)
                } else {
                    // Active, or the image couldn't be loaded: show the alt text
                    // link-colored (same as a plain link); delimiters are dimmed/hidden below.
                    result.addAttribute(.foregroundColor, value: linkColor, range: span.contentRange)
                    let italic = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
                    result.addAttribute(.font, value: italic, range: span.contentRange)
                }

            case .blockquote:
                guard span.fullRange.upperBound <= result.length else { continue }
                // A block quote whose first line is `[!type]` is a callout
                // (GitHub-flavored) — render it with an icon, colored label, and
                // colored bar instead of the plain quote styling.
                if let callout = calloutInfo(forBlockquote: span, markdown: markdown), !cursorInToken {
                    styleCalloutContent(result, span: span, info: callout)
                } else {
                    // Plain block quote — also the editing form of a callout: when
                    // the cursor is inside a callout we fall through here so its raw
                    // `>` / `[!type]` source shows (dimmed) and the markers can be
                    // edited, instead of the box/header/nested chrome.
                    // Attributes must cover fullRange so the first character of each
                    // paragraph (the `> ` delimiter) carries the style/decoration —
                    // the fragment vendor reads the paragraph's first character.
                    result.addAttribute(.paragraphStyle, value: blockquoteParagraphStyle(), range: span.fullRange)
                    result.addAttribute(.blockDecoration,
                                        value: BlockDecoration(.leftBar(color: .tertiaryLabelColor, width: 2)),
                                        range: span.fullRange)
                    result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.contentRange)
                }

            case .listItem(let ordered, let checkbox):
                guard span.fullRange.upperBound <= result.length else { continue }
                styleListItemSpan(result, span: span, markdown: markdown,
                                  ordered: ordered, checkbox: checkbox,
                                  cursorInToken: cursorInToken)

            case .table:
                guard span.fullRange.upperBound <= result.length else { continue }
                styleTableSpan(result, span: span, cursorInToken: cursorInToken)

            case .thematicBreak:
                guard span.fullRange.upperBound <= result.length else { continue }
                if cursorInToken {
                    // Active: show raw dashes, dimmed — but keep the rendered
                    // rule's vertical metrics (forced line height + breathing
                    // space) so clicking in doesn't collapse the block's height
                    // and shift content below.
                    result.addAttribute(.paragraphStyle, value: thematicBreakParagraphStyle(), range: span.fullRange)
                    result.addAttribute(.foregroundColor, value: syntaxDimColor, range: span.fullRange)
                } else {
                    // Non-active: horizontal hairline decoration, hide raw text
                    result.addAttribute(.paragraphStyle, value: thematicBreakParagraphStyle(), range: span.fullRange)
                    result.addAttribute(.blockDecoration,
                                        value: BlockDecoration(.horizontalRule(color: .separatorColor,
                                                                               centerOffset: thematicBreakCenterOffset)),
                                        range: span.fullRange)
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
                    if let overlay = mathOverlay(latex: latex.trimmingCharacters(in: .whitespacesAndNewlines),
                                                 display: display,
                                                 fontSize: contextFont.pointSize) {
                        // Draw the rendered image at the first `$` (hidden, with
                        // kern reserving the image's width) and hide everything
                        // after it — the rest of the opening delimiter, the
                        // source, and the close.
                        let hideStart = span.fullRange.location + 1
                        let hideLen = span.fullRange.upperBound - hideStart
                        let hideRange = NSRange(location: hideStart, length: hideLen)
                        result.addAttribute(.font, value: hiddenFont, range: hideRange)
                        result.addAttribute(.foregroundColor, value: NSColor.clear, range: hideRange)
                        applyOverlay(overlay,
                                     anchor: NSRange(location: span.fullRange.location, length: 1),
                                     in: result)
                        if !display {
                            // Inline math flows within a text line; reserve the
                            // line height so a tall equation (e.g. scaled to a
                            // heading's font) doesn't overlap the line below.
                            reserveLineHeight(overlay.bounds.height,
                                              forOverlayAt: span.fullRange.location,
                                              in: result)
                        }
                        // Display math sits centered on its own line, with
                        // vertical padding and the image's height reserved on
                        // the (first) line that carries it.
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
                                                value: displayMathParagraphStyle(padded: true,
                                                                                 imageHeight: overlay.bounds.height),
                                                range: firstLine)
                        }
                    } else {
                        // Invalid LaTeX: surface the raw source in monospace, tinted.
                        result.addAttribute(.font, value: inlineCodeFont, range: span.fullRange)
                        result.addAttribute(.foregroundColor, value: NSColor.systemRed, range: span.fullRange)
                    }
                }

            case .footnoteReference:
                guard span.fullRange.upperBound <= result.length else { continue }
                // Dim the id like other syntax markers (bullets, etc.) rather than
                // coloring it like a link; when rendered (cursor outside), raise and
                // shrink it into a superscript and hide the `[^`/`]` (below). When
                // active, it stays full size and editable with dimmed delimiters.
                result.addAttribute(.foregroundColor, value: syntaxDimColor, range: span.contentRange)
                if !cursorInToken {
                    let small = NSFont(descriptor: bodyFont.fontDescriptor,
                                       size: bodyFont.pointSize * 0.75) ?? bodyFont
                    result.addAttribute(.font, value: small, range: span.contentRange)
                    result.addAttribute(.baselineOffset, value: bodyFont.pointSize * 0.35,
                                        range: span.contentRange)
                }

            case .footnoteDefinition:
                guard span.fullRange.upperBound <= result.length else { continue }
                // The `[^id]:` marker is dimmed by the delimiter pass below; the
                // definition text after it stays normal. Nothing to add here.
                break

            case .comment:
                guard span.fullRange.upperBound <= result.length else { continue }
                // Reading view hides comments entirely; Edit view dims the whole
                // `%%…%%` (delimiters dimmed again in the delimiter pass). The
                // content is opaque (no inner markdown), so dimming fullRange is
                // enough.
                if hideComments {
                    result.addAttribute(.font, value: hiddenFont, range: span.fullRange)
                    result.addAttribute(.foregroundColor, value: NSColor.clear, range: span.fullRange)
                } else {
                    result.addAttribute(.foregroundColor, value: syntaxDimColor, range: span.fullRange)
                }

            case .lineBreak:
                break  // Delimiter handling done below

            case .escape:
                break  // The escaped char keeps base attributes; the backslash
                       // is hidden/dimmed by the generic delimiter pass below.

            case .htmlTag:
                guard span.contentRange.upperBound <= result.length else { continue }
                // Always literal: color the element name red like math; the
                // `<`/`>`/`/` are dimmed by the generic (non-hideable) pass below.
                result.addAttribute(.foregroundColor, value: theme.mathOperatorColor,
                                    range: span.contentRange)

            case .htmlFormat(let tag):
                guard span.fullRange.upperBound <= result.length else { continue }
                // Inactive: hide the tags (delimiter pass) and apply the rendered
                // attribute to the inner content. Active: the raw tags show
                // colored (handled in the delimiter pass).
                if !cursorInToken {
                    applyHTMLFormatAttribute(result, tag: tag, range: span.contentRange)
                }
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
                        // Dim the visible marker, but skip any leading whitespace in
                        // the delimiter range — it was hidden during content styling
                        // and dimming it here would re-show it (the rescue parser's
                        // delimiter includes that whitespace).
                        let nsDelim = (markdown as NSString).substring(with: dr) as NSString
                        let firstNonWS = nsDelim.rangeOfCharacter(
                            from: CharacterSet(charactersIn: " \t").inverted)
                        let mStart = dr.location +
                            (firstNonWS.location == NSNotFound ? dr.length : firstNonWS.location)
                        if mStart < dr.upperBound {
                            result.addAttribute(.foregroundColor, value: syntaxDimColor,
                                                range: NSRange(location: mStart, length: dr.upperBound - mStart))
                        }
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
                } else if case .htmlFormat = span.kind {
                    // Whitelisted tag pair: show the raw tags (dim brackets, red
                    // name) when active; hide them when the content is rendered.
                    if cursorInToken {
                        styleRawHTMLTag(result, range: dr)
                    } else {
                        result.addAttribute(.font, value: hiddenFont, range: dr)
                        result.addAttribute(.foregroundColor, value: NSColor.clear, range: dr)
                    }
                } else if case .comment = span.kind {
                    // Comment `%%`: hidden in reading view, dimmed otherwise —
                    // matching the content styling above.
                    if hideComments {
                        result.addAttribute(.font, value: hiddenFont, range: dr)
                        result.addAttribute(.foregroundColor, value: NSColor.clear, range: dr)
                    } else {
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

    /// Applies a whitelisted HTML tag's rendered formatting to `range` (the inner
    /// content). Unknown tags are no-ops (handled as colored source elsewhere).
    private func applyHTMLFormatAttribute(_ result: NSMutableAttributedString,
                                          tag: String, range: NSRange) {
        switch tag {
        case "u":
            result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case "mark":
            result.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: range)
        case "kbd":
            result.addAttribute(.font, value: inlineCodeFont, range: range)
            result.addAttribute(.backgroundColor, value: inlineCodeBackground, range: range)
        case "sub", "sup":
            let small = NSFont(descriptor: bodyFont.fontDescriptor, size: bodyFont.pointSize * 0.75) ?? bodyFont
            result.addAttribute(.font, value: small, range: range)
            let offset = tag == "sub" ? -bodyFont.pointSize * 0.25 : bodyFont.pointSize * 0.35
            result.addAttribute(.baselineOffset, value: offset, range: range)
        default:
            break
        }
    }

    /// Dims an HTML tag's punctuation (`<`, `/`, attrs, `>`) and colors its
    /// element name red — the active-state look for a `.htmlFormat` pair, matching
    /// how `.htmlTag` colored source reads.
    private func styleRawHTMLTag(_ result: NSMutableAttributedString, range: NSRange) {
        result.addAttribute(.foregroundColor, value: syntaxDimColor, range: range)
        let ns = result.string as NSString
        var i = range.location
        let end = range.upperBound
        while i < end, ns.character(at: i) == 0x3C || ns.character(at: i) == 0x2F { i += 1 }  // < /
        var j = i
        func isAlphaNum(_ c: unichar) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39)
        }
        while j < end, isAlphaNum(ns.character(at: j)) { j += 1 }
        if j > i {
            result.addAttribute(.foregroundColor, value: theme.mathOperatorColor,
                                range: NSRange(location: i, length: j - i))
        }
    }

    /// Plain monospaced styling for source mode: the raw markdown with no
    /// markup interpretation (no hidden delimiters, overlays, or decorations).
    func sourceStyled(_ markdown: String) -> NSAttributedString {
        let mono = theme.monospaceFont(ofSize: bodyFont.pointSize)
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = theme.lineSpacing
        return NSAttributedString(string: markdown, attributes: [
            .font: mono,
            .foregroundColor: foregroundColor,
            .paragraphStyle: ps,
        ])
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

        let styled: NSAttributedString
        switch viewMode {
        case .edit:    styled = styleBlock(block.content, cursorPosition: cursorInBlock)
        case .reading: styled = styleBlock(block.content, cursorPosition: nil, hideComments: true)
        case .source:  styled = sourceStyled(block.content)
        }
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


