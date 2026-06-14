import AppKit

// MARK: - Callout Rendering
//
// A callout is a block quote whose first line is `[!type]` (case-insensitive).
// swift-markdown gives us a plain `.blockquote` span; here we detect the marker
// and render the header line as an icon + title image (hiding the raw
// `[!type] …` source), with a customizable colored border + tinted background.
// Colors resolve per light/dark appearance. While the cursor is inside the
// callout the raw, editable marker is shown instead.

extension EditorTextView {

    /// A detected callout on a block-quote span, with ranges mapped to absolute
    /// offsets within the block string.
    struct CalloutInfo {
        let marker: Callout.Marker
        let style: CalloutStyle
        /// `[ '[' … end-of-first-line )` — replaced by the icon+title image.
        let headerRange: NSRange
        /// Capitalized type name, or the custom title if the header has one.
        let title: String
    }

    /// Returns callout info if `span` (a `.blockquote`) begins with a known
    /// `[!type]` marker on its first line, else `nil` (a plain block quote).
    func calloutInfo(forBlockquote span: SyntaxHighlighter.Span, markdown: String) -> CalloutInfo? {
        guard let firstDelim = span.delimiterRanges.min(by: { $0.location < $1.location })
        else { return nil }
        let ns = markdown as NSString
        let contentStart = firstDelim.upperBound
        let blockEnd = min(span.fullRange.upperBound, ns.length)
        guard contentStart < blockEnd else { return nil }

        let searchRange = NSRange(location: contentStart, length: blockEnd - contentStart)
        let nl = ns.range(of: "\n", options: [], range: searchRange)
        let lineEnd = nl.location == NSNotFound ? blockEnd : nl.location
        let firstLine = ns.substring(with: NSRange(location: contentStart, length: lineEnd - contentStart))

        guard let rel = Callout.parseMarker(firstLine),
              let style = Callout.style(for: rel.type, overrides: calloutStyleOverrides) else { return nil }

        func abs(_ r: NSRange) -> NSRange { NSRange(location: r.location + contentStart, length: r.length) }
        let marker = Callout.Marker(type: rel.type,
                                    openBracket: abs(rel.openBracket),
                                    typeRange: abs(rel.typeRange),
                                    closeBracket: abs(rel.closeBracket))

        let titleStart = marker.closeBracket.upperBound
        let customRaw = titleStart < lineEnd
            ? ns.substring(with: NSRange(location: titleStart, length: lineEnd - titleStart)) : ""
        let title = Callout.title(type: marker.type, customTitle: customRaw)
        let headerRange = NSRange(location: marker.openBracket.location,
                                  length: lineEnd - marker.openBracket.location)

        return CalloutInfo(marker: marker, style: style, headerRange: headerRange, title: title)
    }

    /// Applies callout styling. `active` shows the raw marker (dimmed, editable);
    /// otherwise the header is replaced by an icon + title image.
    func styleCalloutContent(_ result: NSMutableAttributedString,
                             span: SyntaxHighlighter.Span,
                             info: CalloutInfo,
                             active: Bool) {
        guard span.fullRange.upperBound <= result.length else { return }
        let c = resolvedCalloutColors(info.style)

        // The box is drawn by DecoratedTextLayoutFragment behind every
        // paragraph of the callout; the fragments tile into one continuous box.
        func box(bottomPad: CGFloat) -> BlockDecoration {
            BlockDecoration(.box(background: c.background,
                                 borderColor: c.border,
                                 borderEdges: info.style.borderEdges,
                                 borderWidth: info.style.borderWidth,
                                 bottomPad: bottomPad))
        }
        result.addAttribute(.blockDecoration, value: box(bottomPad: 0),
                            range: span.fullRange)
        result.addAttribute(.paragraphStyle, value: calloutParagraphStyle(),
                            range: span.fullRange)
        // Bottom breathing room: the last line's box carries a bottomPad, which
        // grows that fragment's frame (see layoutFragmentFrame). The extra space
        // is genuine clickable text space below the last line — clicks there
        // land on the callout, the next block tiles clear, and the box covers
        // it — no dead zone, no trailing paragraph spacing.
        let ns = result.string as NSString
        var lastLineStart = span.fullRange.location
        let nl = ns.range(of: "\n", options: .backwards,
                          range: span.fullRange)
        if nl.location != NSNotFound { lastLineStart = nl.upperBound }
        let lastLine = NSRange(location: lastLineStart,
                               length: span.fullRange.upperBound - lastLineStart)
        result.addAttribute(.blockDecoration, value: box(bottomPad: calloutBottomPad),
                            range: lastLine)

        let m = info.marker
        if active {
            // Editing: dim the raw "[!type]" marker; the custom title (if any)
            // stays as normal, editable text.
            let markerFull = NSRange(location: m.openBracket.location,
                                     length: m.closeBracket.upperBound - m.openBracket.location)
            if markerFull.upperBound <= result.length {
                result.addAttribute(.foregroundColor, value: syntaxDimColor, range: markerFull)
            }
            return
        }

        // Rendered: hide the whole header, draw an icon + title image at the
        // first character via a fragment overlay.
        let header = info.headerRange
        guard header.length > 0, header.upperBound <= result.length else { return }
        result.addAttribute(.font, value: hiddenFont, range: header)
        result.addAttribute(.foregroundColor, value: NSColor.clear, range: header)
        if let overlay = calloutHeaderOverlay(symbolName: info.style.symbolName,
                                              title: info.title, color: c.accent,
                                              iconNudge: info.style.iconBaselineNudge) {
            applyOverlay(overlay, anchor: NSRange(location: header.location, length: 1),
                         in: result)
            // Top breathing room: a raised minimum line height on the header
            // line — still clickable text space, the box covers it.
            let ns = result.string as NSString
            let nl = ns.range(of: "\n", options: [], range: span.fullRange)
            let headerLineEnd = nl.location == NSNotFound ? span.fullRange.upperBound : nl.location
            let headerLine = NSRange(location: span.fullRange.location,
                                     length: headerLineEnd - span.fullRange.location)
            result.addAttribute(
                .paragraphStyle,
                value: calloutParagraphStyle(minimumLineHeight: overlay.bounds.height + calloutTopPad),
                range: headerLine)
        }
    }

    // MARK: Colors (appearance-aware)

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func resolvedCalloutColors(_ style: CalloutStyle)
        -> (accent: NSColor, border: NSColor, background: NSColor) {
        let dark = isDarkAppearance
        let accent = NSColor(hex: style.accentHex(dark: dark)) ?? accentColor
        let border = NSColor(hex: style.resolvedBorderHex(dark: dark)) ?? accent
        let background: NSColor
        if let bgHex = style.explicitBackgroundHex(dark: dark), let bg = NSColor(hex: bgHex) {
            background = bg
        } else {
            background = accent.withAlphaComponent(style.backgroundAlpha)
        }
        return (accent, border, background)
    }

    // MARK: Padding constants (shared by the box and the header image)

    /// Top breathing room — baked into the header image so it's part of the
    /// header *line* (clickable text space), not dead block padding.
    private var calloutTopPad: CGFloat { bodyFont.pointSize * 0.8 }
    /// Bottom breathing room. Delivered by growing the last line's layout
    /// fragment frame (a box `bottomPad`), so it is genuine clickable text
    /// space below the last line — not trailing paragraph spacing, which
    /// TextKit 2 leaves out of the fragment and which clicks would miss.
    var calloutBottomPad: CGFloat { bodyFont.pointSize * 0.8 }

    // MARK: Paragraph style (text insets; the box itself is a BlockDecoration)

    /// Text insets the NSTextBlock padding used to provide. The left inset is
    /// kept small so the callout's text lines up with a plain block quote's —
    /// the quote's 2pt bar inset matches this 2pt — and the top breathing room
    /// lives in the header image (clickable text space). The bottom breathing
    /// room is the last line's box `bottomPad` (which grows that fragment's
    /// frame), so the drawn box covers it and clicks there land on the
    /// callout's last line — no trailing paragraph spacing needed.
    private func calloutParagraphStyle(minimumLineHeight: CGFloat = 0) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = bodyParagraphStyle.lineSpacing
        ps.firstLineHeadIndent = 2
        // Hanging indent so wrapped body lines align after the `> ` marker,
        // matching list items and plain blockquotes.
        ps.headIndent = 2 + quoteMarkerWidth
        ps.tailIndent = -10
        ps.minimumLineHeight = minimumLineHeight
        return ps
    }

    // MARK: Header image (icon + title)

    /// Draws "icon  Title" into one image, tinted to the callout color, and
    /// wraps it in a `FragmentOverlay`. Returns `nil` if the SF Symbol can't
    /// be resolved. The top breathing room is NOT in the image — the caller
    /// raises the header line's minimum line height instead.
    private func calloutHeaderOverlay(symbolName: String, title: String, color: NSColor,
                                      iconNudge: CGFloat) -> FragmentOverlay? {
        let pointSize = bodyFont.pointSize
        let symConfig = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symConfig) else { return nil }

        let titleFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: color]
        let titleStr = NSAttributedString(string: title, attributes: titleAttrs)
        let titleSize = titleStr.size()

        let gap = pointSize * 0.3
        let symW = symbol.size.width, symH = symbol.size.height
        let contentHeight = ceil(max(symH, titleSize.height))
        let width = ceil(symW + gap + titleSize.width)

        let image = NSImage(size: NSSize(width: width, height: contentHeight), flipped: false) { _ in
            let titleY = (contentHeight - titleSize.height) / 2
            titleStr.draw(at: NSPoint(x: symW + gap, y: titleY))
            // Center the icon on the title's cap height (its optical middle) rather
            // than the full line box, so tall-glyph symbols don't sit high.
            let baseline = titleY + abs(titleFont.descender)
            let capCenter = baseline + titleFont.capHeight / 2
            symbol.draw(in: NSRect(x: 0, y: capCenter - symH / 2 + iconNudge, width: symW, height: symH))
            return true
        }

        return FragmentOverlay(image: image,
                               bounds: CGRect(x: 0, y: -pointSize * 0.15,
                                              width: width, height: contentHeight))
    }
}
