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

    /// Color for dimmed syntax delimiters (*, **, `, #, …) and for the ink of
    /// syntax that stays visible but recedes (%%comments%%, ^blockrefs). In dark
    /// mode `tertiaryLabelColor` (0.25 white) sits too close to the background,
    /// so the whole dim tier moves to the marker gray — one tertiary substitute
    /// for every dimmed thing on the dark side. Light mode is untouched.
    var syntaxDimColor: NSColor {
        isDarkAppearance ? Self.darkChromeGray : .tertiaryLabelColor
    }

    /// Color for links and wikilinks — always the theme's accent blue, independent of
    /// the system accent so links stay consistently blue across user accent preferences.
    var linkColor: NSColor { theme.linkBlueColor }

    /// Monospaced font for tables.
    var tableFont: NSFont { renderingMonospaceFont }

    /// Monospaced font for code blocks.
    var codeBlockFont: NSFont { renderingMonospaceFont }

    /// Font used to visually hide delimiter characters.
    /// Near-zero size makes them effectively invisible and zero-width.
    var hiddenFont: NSFont {
        if let cachedHiddenFont { return cachedHiddenFont }
        let font = NSFont.systemFont(ofSize: 0.01)
        cachedHiddenFont = font
        return font
    }

    /// Monospaced font for inline code spans.
    var inlineCodeFont: NSFont { renderingMonospaceFont }

    private var renderingMonospaceFont: NSFont {
        if let cachedMonospaceFont { return cachedMonospaceFont }
        let font = theme.monospaceFont()
        cachedMonospaceFont = font
        return font
    }

    /// Subtle background color for inline code spans. The 10% wash reads fine
    /// on white but nearly disappears on the dark background (it lands ~4 levels
    /// above it), so dark mode more than doubles the alpha to hold the same
    /// visible step as Read mode's --inline-code-bg.
    var inlineCodeBackground: NSColor {
        NSColor(calibratedWhite: 0.5, alpha: isDarkAppearance ? 0.22 : 0.1)
    }

    /// Stable cache-key representation for dynamic AppKit colors. Hash values
    /// alone can collide, and unresolved semantic colors can change with the
    /// view's appearance.
    func renderingCacheColorKey(_ color: NSColor) -> String {
        var resolved = color
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB) ?? color
        }
        guard let rgb = resolved.usingColorSpace(.deviceRGB) else {
            return String(reflecting: resolved)
        }
        return String(
            format: "%.6f,%.6f,%.6f,%.6f",
            rgb.redComponent,
            rgb.greenComponent,
            rgb.blueComponent,
            rgb.alphaComponent
        )
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

    /// Ink for the `---` hairline. `separatorColor` sits at ~10% and is nearly
    /// invisible on the dark background, so dark mode uses the shared marker
    /// gray instead; light mode keeps `separatorColor`. Read mode's `--hr` matches.
    var thematicBreakColor: NSColor {
        isDarkAppearance ? Self.darkHRuleGray : .separatorColor
    }

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
             .code, .link, .image, .embed, .lineBreak,
             .heading, .blockquote(_), .footnoteReference, .escape:
            return true
        case .listItem, .table, .codeBlock, .thematicBreak, .footnoteDefinition, .comment,
             .htmlTag, .htmlFormat, .tag, .blockRef:
            // htmlTag: always colored source (brackets dimmed by the generic
            // pass). htmlFormat: handled explicitly in the delimiter loop.
            // tag: a pill, nothing hides. blockRef: hidden/dimmed like a comment
            // via its own branch in the delimiter loop.
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

        let spans = SyntaxHighlighter.parse(markdown, linkDefinitions: linkDefState.defsText,
                                            features: markdownFeatures)

        // The font already applied at `loc` — the enclosing heading's when
        // inside one, else the base body font. Inline spans derive their font
        // from it so `# **bold** and `code`` keeps the heading's size. Spans
        // apply in location order, so a heading (at the block start) styles
        // its fullRange before any inner span reads the context.
        func contextFont(at loc: Int) -> NSFont {
            guard loc >= 0, loc < result.length else { return bodyFont }
            return result.attribute(.font, at: loc, effectiveRange: nil) as? NSFont ?? bodyFont
        }
        // The mono font matching `ctx`'s scale: the plain inline-code font in
        // body text, scaled up inside a heading.
        func monoFont(for ctx: NSFont) -> NSFont {
            let scale = ctx.pointSize / bodyFont.pointSize
            return scale == 1 ? inlineCodeFont
                : theme.monospaceFont(ofSize: inlineCodeFont.pointSize * scale)
        }

        for span in spans {
            let cursorInToken = cursorPosition.map {
                $0 >= span.fullRange.location && $0 <= span.fullRange.upperBound
            } ?? false

            // --- Content styling (applied first) ---
            switch span.kind {
            case .bold:
                guard span.contentRange.upperBound <= result.length else { continue }
                let ctx = contextFont(at: span.contentRange.location)
                let bold = NSFontManager.shared.convert(ctx, toHaveTrait: .boldFontMask)
                result.addAttribute(.font, value: bold, range: span.contentRange)

            case .italic:
                guard span.contentRange.upperBound <= result.length else { continue }
                let ctx = contextFont(at: span.contentRange.location)
                let italic = NSFontManager.shared.convert(ctx, toHaveTrait: .italicFontMask)
                result.addAttribute(.font, value: italic, range: span.contentRange)

            case .boldItalic:
                guard span.contentRange.upperBound <= result.length else { continue }
                let ctx = contextFont(at: span.contentRange.location)
                let bi = NSFontManager.shared.convert(ctx, toHaveTrait: [.boldFontMask, .italicFontMask])
                result.addAttribute(.font, value: bi, range: span.contentRange)

            case .code:
                guard span.contentRange.upperBound <= result.length else { continue }
                let ctx = contextFont(at: span.contentRange.location)
                result.addAttribute(.font, value: monoFont(for: ctx), range: span.contentRange)
                result.addAttribute(.foregroundColor, value: foregroundColor, range: span.contentRange)
                result.addAttribute(.backgroundColor, value: inlineCodeBackground, range: span.contentRange)

            case .codeBlock(let language):
                guard span.fullRange.upperBound <= result.length else { continue }
                // Monospace across the fullRange, fences included: the fence
                // line keeps its natural (now code-line) height whether shown
                // dimmed (active) or ink-cleared (rendered, blockquote-style).
                result.addAttribute(.font, value: codeBlockFont, range: span.fullRange)
                highlightCodeBlock(result, contentRange: span.contentRange, language: language)
                if !cursorInToken {
                    styleCodeBlockBox(result, span: span, language: language)
                }

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

            case .image(let destination, let width, let height):
                guard span.fullRange.upperBound <= result.length else { continue }
                if !cursorInToken, let overlay = imageOverlay(destination: destination,
                                                              width: width, height: height) {
                    // Rendered: draw the image at the leading character (`!` of
                    // `![alt](path)`, `<` of `<img …>`) and hide the rest of the
                    // source, reserving the line height so the picture has room.
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
                    reserveLineHeight(ascent: overlay.bounds.height + overlay.bounds.minY,
                                      descent: -overlay.bounds.minY,
                                      forOverlayAt: span.fullRange.location, in: result)
                } else if (markdown as NSString).character(at: span.fullRange.location) == 0x3C {
                    // Active (or pending) `<img …>`: show the raw tag as colored
                    // HTML source, like any other tag.
                    styleRawHTMLTag(result, range: span.fullRange)
                } else {
                    // Active, or the image couldn't be loaded: show the alt text
                    // link-colored (same as a plain link); delimiters are dimmed/hidden below.
                    result.addAttribute(.foregroundColor, value: linkColor, range: span.contentRange)
                    let italic = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
                    result.addAttribute(.font, value: italic, range: span.contentRange)
                }

            case .embed(let destination):
                guard span.fullRange.upperBound <= result.length else { continue }
                // A non-image `![[file]]` embed: draw the per-type "unsupported"
                // placeholder (same overlay as a blocked image) when rendered,
                // hiding the `[[…]]` source and reserving line height. Active
                // (cursor inside): the raw `![[file]]` shows with base attributes.
                if !cursorInToken, let overlay = embedOverlay(destination: destination) {
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
                    reserveLineHeight(ascent: overlay.bounds.height + overlay.bounds.minY,
                                      descent: -overlay.bounds.minY,
                                      forOverlayAt: span.fullRange.location, in: result)
                }

            case .blockquote(let depth):
                guard span.fullRange.upperBound <= result.length else { continue }
                // A block quote whose first line is `[!type]` is a callout
                // (GitHub-flavored) — render it with an icon, colored label, and
                // colored bar instead of the plain quote styling. Only depth 0
                // ever detects as a callout: a callout nested inside a plain
                // quote stays literal (see SyntaxHighlighter+Walker's
                // visitBlockQuote), so no deeper span is ever callout-shaped.
                if let callout = calloutInfo(forBlockquote: span, markdown: markdown), !cursorInToken {
                    styleCalloutContent(result, span: span, info: callout)
                } else {
                    // Plain block quote (any nesting depth). Indent and draw
                    // this level's own bar regardless of active/inactive — the
                    // generic delimiter pass (elsewhere in this function)
                    // separately decides whether this level's own `>` marker
                    // is hidden (inactive) or shown dimmed (active/editing).
                    //
                    // Per-level indentation comes from the width-preserved
                    // hidden `> ` markers alone (one more per level), so the
                    // first-line indent stays constant — adding a paragraph
                    // indent per depth too would double the step. Only the
                    // hanging indent grows, to keep wrapped lines clear of
                    // all this line's markers.
                    //
                    // A nested quote's span range is a *subset* of its
                    // ancestors' (processed earlier, in outer-to-inner order:
                    // the walker emits a parent before descending to its
                    // children), so stacking here only has to keep whatever
                    // decoration the ancestor already painted over this same
                    // range and append this level's own bar — bar x positions
                    // are absolute per level, independent of the line.
                    // The fragment vendor reads paragraph-level attributes at
                    // paragraph offset 0, but a nested span's range starts at
                    // its *own* `>` — past the ancestors' markers on its first
                    // line. Extend back to the line start so the line's
                    // paragraph carries this level's decoration/indent (else
                    // the line draws only the ancestor's single bar).
                    let lineStart = (markdown as NSString)
                        .lineRange(for: NSRange(location: span.fullRange.location, length: 0)).location
                    let paraRange = NSRange(location: lineStart,
                                            length: span.fullRange.upperBound - lineStart)
                    let ps = blockquoteParagraphStyle().mutableCopy() as! NSMutableParagraphStyle
                    ps.headIndent += CGFloat(depth) * quoteMarkerWidth
                    result.addAttribute(.paragraphStyle, value: ps, range: paraRange)

                    // The quote's own bar hugs the text top on its *first* line
                    // only (see BlockDecoration.hugsTextTop) — interior lines
                    // fill their whole fragment so the bar tiles gap-free. The
                    // ancestor stack is read per sub-range: an ancestor's own
                    // first line (hugging) can coincide with this span's first
                    // line, but its interior lines never hug.
                    let firstLineEnd = min((markdown as NSString)
                        .lineRange(for: NSRange(location: lineStart, length: 0)).upperBound,
                        paraRange.upperBound)
                    let firstRange = NSRange(location: lineStart, length: firstLineEnd - lineStart)
                    let restRange = NSRange(location: firstLineEnd,
                                            length: paraRange.upperBound - firstLineEnd)
                    for (range, hugs) in [(firstRange, true), (restRange, false)] {
                        guard range.length > 0 else { continue }
                        let ownBar = BlockDecoration(.leftBar(color: syntaxDimColor, width: 2),
                                                     inset: CGFloat(depth) * quoteMarkerWidth,
                                                     hugsTextTop: hugs)
                        if depth == 0 {
                            result.addAttribute(.blockDecoration, value: ownBar, range: range)
                        } else {
                            let ancestor = result.attribute(.blockDecoration, at: range.location,
                                                            effectiveRange: nil)
                            let kept: [BlockDecoration]
                            if let list = ancestor as? BlockDecorationList {
                                kept = list.decorations
                            } else if let single = ancestor as? BlockDecoration {
                                kept = [single]
                            } else {
                                kept = []
                            }
                            result.addAttribute(.blockDecoration,
                                                value: BlockDecorationList(kept + [ownBar]),
                                                range: range)
                        }
                    }

                    // Only the outermost span fills content color: `contentRange`
                    // only trims a span's very first/last delimiter, not ones in
                    // the middle (a nested quote's own markers on later lines) —
                    // a nested span's fill would repaint an ancestor's marker
                    // right back to visible, undoing that ancestor's delimiter
                    // pass (which already ran, earlier in this same loop). The
                    // outermost span's fill already covers all nested text, so
                    // deeper spans don't need to (re-)apply it.
                    if depth == 0 {
                        result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                            range: span.contentRange)
                    }
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
                                        value: BlockDecoration(.horizontalRule(color: thematicBreakColor,
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
                        // A `$$…$$` run gets block layout only when it owns the
                        // whole block — either the block is nothing but the run
                        // (own-line display math, centered), or the only thing
                        // before it is a list marker (`1. $$…$$` — the block sits
                        // indented under the marker). Anything else on the line
                        // (prose) flows inline like `$…$` math.
                        let blockNS = markdown as NSString
                        let full = span.fullRange
                        let nonWS = CharacterSet.whitespacesAndNewlines.inverted
                        let afterR = NSRange(location: full.upperBound,
                                             length: blockNS.length - full.upperBound)
                        let afterClear = blockNS.rangeOfCharacter(from: nonWS, options: [], range: afterR).location == NSNotFound
                        let beforeStr = blockNS.substring(to: full.location)
                        let beforeClear = beforeStr.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" }
                        // A leading list marker (and nothing else) still lets the
                        // run own the block; keep the marker's paragraph style so
                        // the equation sits indented under it.
                        let listMarkerBefore = !beforeClear && BlockParser.isListMarkerOnly(beforeStr)
                        let displayOwnsBlock = display && afterClear && (beforeClear || listMarkerBefore)
                        if !displayOwnsBlock {
                            // Inline math — and a display run sharing its line
                            // with prose — flows within the text line; reserve
                            // the line height so a tall equation (e.g. scaled to
                            // a heading's font, or a lone integral with a big
                            // descent) doesn't overlap the lines around it.
                            reserveLineHeight(ascent: overlay.bounds.height + overlay.bounds.minY,
                                              descent: -overlay.bounds.minY,
                                              forOverlayAt: span.fullRange.location,
                                              in: result)
                        }
                        // Display math sits on its own line with the image's
                        // ascent/descent reserved on the (first) line that carries
                        // it, plus vertical padding.
                        if displayOwnsBlock {
                            let fullStr = result.string as NSString
                            let nl = fullStr.range(of: "\n", options: [], range: span.fullRange)
                            let imageDescent = -overlay.bounds.minY
                            let imageAscent = overlay.bounds.height - imageDescent
                            if listMarkerBefore {
                                // Inside a list item: keep the list paragraph style
                                // (indent set by styleListItemSpan) and only reserve
                                // the image height + display spacing on the marker's
                                // line, so the equation reads as a block indented
                                // under the marker instead of cramming the line. The
                                // firstLine starts at the paragraph head (0) — the
                                // marker precedes the span — so char 0's style, which
                                // TextKit uses for the paragraph, carries the height.
                                let firstLineEnd = nl.location == NSNotFound
                                    ? span.fullRange.upperBound : nl.location + 1
                                let firstLine = NSRange(location: 0, length: firstLineEnd)
                                let base = (result.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                                    as? NSParagraphStyle) ?? bodyParagraphStyle
                                let ps = (base.mutableCopy() as! NSMutableParagraphStyle)
                                let pad = bodyFont.pointSize * 0.9
                                ps.paragraphSpacingBefore = pad
                                ps.paragraphSpacing = pad + imageDescent
                                ps.minimumLineHeight = imageAscent
                                result.addAttribute(.paragraphStyle, value: ps, range: firstLine)
                            } else {
                                result.addAttribute(.paragraphStyle,
                                                    value: displayMathParagraphStyle(padded: false),
                                                    range: span.fullRange)
                                let firstLine = nl.location == NSNotFound
                                    ? span.fullRange
                                    : NSRange(location: span.fullRange.location,
                                              length: nl.location - span.fullRange.location + 1)
                                result.addAttribute(.paragraphStyle,
                                                    value: displayMathParagraphStyle(padded: true,
                                                                                     imageAscent: imageAscent,
                                                                                     imageDescent: imageDescent),
                                                    range: firstLine)
                            }
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
                    let ctx = contextFont(at: span.contentRange.location)
                    let small = NSFont(descriptor: ctx.fontDescriptor,
                                       size: ctx.pointSize * 0.75) ?? ctx
                    result.addAttribute(.font, value: small, range: span.contentRange)
                    result.addAttribute(.baselineOffset, value: ctx.pointSize * 0.35,
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

            case .tag:
                guard span.contentRange.upperBound <= result.length else { continue }
                // Pill: accent text on a faint accent wash over the whole `#tag`.
                // No delimiter range, so nothing hides — the `#` stays visible.
                result.addAttribute(.backgroundColor, value: linkColor.withAlphaComponent(0.15),
                                    range: span.contentRange)
                result.addAttribute(.foregroundColor, value: linkColor, range: span.contentRange)

            case .blockRef:
                guard span.fullRange.upperBound <= result.length else { continue }
                // Like a comment: hidden in reading view, dimmed otherwise. The
                // delimiter pass repeats this over the token so it wins.
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
                } else if case .codeBlock = span.kind {
                    // Fenced code: like blockquote's `>`, the fence keeps its
                    // normal size (its line is the box's top/bottom breathing
                    // room) but draws no ink when rendered; dimmed when active.
                    if cursorInToken {
                        result.addAttribute(.foregroundColor, value: syntaxDimColor, range: dr)
                    } else {
                        result.addAttribute(.foregroundColor, value: NSColor.clear, range: dr)
                    }
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
                } else if case .blockRef = span.kind {
                    // `^id`: hidden in reading view, dimmed otherwise (matches
                    // the content styling and the comment treatment).
                    if hideComments {
                        result.addAttribute(.font, value: hiddenFont, range: dr)
                        result.addAttribute(.foregroundColor, value: NSColor.clear, range: dr)
                    } else {
                        result.addAttribute(.foregroundColor, value: syntaxDimColor, range: dr)
                    }
                } else if case .heading = span.kind, cursorPosition != nil {
                    // A heading is one logical line. Keep its marker visible
                    // while the caret is anywhere on that line so moving between
                    // inline tokens does not make the leading `#` flicker.
                    result.addAttribute(.foregroundColor, value: syntaxDimColor, range: dr)
                } else if cursorInToken || !isDelimiterHideable(span.kind) {
                    // Visible: dim the delimiters
                    result.addAttribute(.foregroundColor, value: syntaxDimColor, range: dr)
                } else if case .blockquote(_) = span.kind {
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
    /// Fonts derive from the one already applied at the range (the enclosing
    /// heading's, when inside one), so sizes nest like other inline spans.
    private func applyHTMLFormatAttribute(_ result: NSMutableAttributedString,
                                          tag: String, range: NSRange) {
        let ctx = (range.location < result.length
            ? result.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            : nil) ?? bodyFont
        switch tag {
        case "u":
            result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case "mark":
            result.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: range)
        case "kbd":
            let scale = ctx.pointSize / bodyFont.pointSize
            let mono = scale == 1 ? inlineCodeFont
                : theme.monospaceFont(ofSize: inlineCodeFont.pointSize * scale)
            result.addAttribute(.font, value: mono, range: range)
            result.addAttribute(.backgroundColor, value: inlineCodeBackground, range: range)
        case "sub", "sup":
            let small = NSFont(descriptor: ctx.fontDescriptor, size: ctx.pointSize * 0.75) ?? ctx
            result.addAttribute(.font, value: small, range: range)
            let offset = tag == "sub" ? -ctx.pointSize * 0.25 : ctx.pointSize * 0.35
            result.addAttribute(.baselineOffset, value: offset, range: range)
        case "small":
            let fine = NSFont(descriptor: ctx.fontDescriptor, size: ctx.pointSize * 0.85) ?? ctx
            result.addAttribute(.font, value: fine, range: range)
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

    /// Dim monospaced styling for a YAML front-matter block: like `sourceStyled`
    /// but faint, and — crucially — the YAML text is never parsed as markdown.
    func styleFrontMatter(_ markdown: String) -> NSAttributedString {
        let mono = theme.monospaceFont()   // the mono font + size recorded in settings
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = theme.lineSpacing
        return NSAttributedString(string: markdown, attributes: [
            .font: mono,
            .foregroundColor: syntaxDimColor,
            .paragraphStyle: ps,
        ])
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
        if case .frontMatter = block.kind, viewMode != .source {
            // YAML front matter: flat dim monospace. Never run YAML through the
            // markdown span parser — a `- x` line would list-style and `#x`
            // would tag-style. (Source mode still shows plain raw mono below.)
            styled = styleFrontMatter(block.content)
        } else {
            switch viewMode {
            case .edit:    styled = styleBlock(block.content, cursorPosition: cursorInBlock)
            case .reading: styled = styleBlock(block.content, cursorPosition: nil, hideComments: true)
            case .source:  styled = sourceStyled(block.content)
            }
        }
        let offset = block.range.location

        styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length), options: []) { attrs, range, _ in
            let tsRange = NSRange(location: range.location + offset, length: range.length)
            ts.setAttributes(attrs, range: tsRange)
        }

        // Reset the separator newlines adjacent to the block. No block's
        // styled range covers them, and a character inserted at a block
        // boundary inherits its neighbor's attributes (e.g. a display-math
        // block's centered paragraph style), which would otherwise stick
        // forever — a full recompose leaves separators at base attributes,
        // so the in-place path must too.
        let nsStr = ts.string as NSString
        if offset > 0, nsStr.character(at: offset - 1) == 0x0A {
            ts.setAttributes(baseAttributes, range: NSRange(location: offset - 1, length: 1))
        }
        let after = block.range.upperBound
        if after < nsStr.length, nsStr.character(at: after) == 0x0A {
            ts.setAttributes(baseAttributes, range: NSRange(location: after, length: 1))
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
