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

        result.addAttribute(.paragraphStyle,
                            value: calloutParagraphStyle(borderColor: c.border,
                                                         backgroundColor: c.background,
                                                         edges: info.style.borderEdges,
                                                         borderWidth: info.style.borderWidth),
                            range: span.fullRange)

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

        // Rendered: hide the whole header, draw an icon + title image on the first
        // character.
        let header = info.headerRange
        guard header.length > 0, header.upperBound <= result.length else { return }
        result.addAttribute(.font, value: hiddenFont, range: header)
        result.addAttribute(.foregroundColor, value: NSColor.clear, range: header)
        if let att = calloutHeaderAttachment(symbolName: info.style.symbolName,
                                             title: info.title, color: c.accent,
                                             iconNudge: info.style.iconBaselineNudge) {
            result.addAttribute(.attachment, value: att,
                                range: NSRange(location: header.location, length: 1))
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
    /// Bottom breathing room (kept as block padding; slightly less, to balance).
    private var calloutBottomPad: CGFloat { bodyFont.pointSize * 0.65 }

    // MARK: Paragraph style (border / background / padding)

    private func calloutParagraphStyle(borderColor: NSColor, backgroundColor: NSColor,
                                       edges: CalloutStyle.Edges, borderWidth: CGFloat) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = bodyParagraphStyle.lineSpacing
        ps.paragraphSpacing = bodyParagraphStyle.paragraphSpacing

        // One block instance shared across the callout's lines renders as a single
        // continuous box, so borders/background/padding wrap the whole callout
        // (padding only at the outer top/bottom, not between lines).
        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)
        block.backgroundColor = backgroundColor

        let left   = NSRectEdge(rawValue: 0)!   // minX
        let top     = NSRectEdge(rawValue: 1)!  // minY (top, flipped text coords)
        let right  = NSRectEdge(rawValue: 2)!   // maxX
        let bottom = NSRectEdge(rawValue: 3)!   // maxY
        let edgeMap: [(CalloutStyle.Edges, NSRectEdge)] =
            [(.left, left), (.top, top), (.right, right), (.bottom, bottom)]
        for (e, rectEdge) in edgeMap where edges.contains(e) {
            block.setWidth(borderWidth, type: .absoluteValueType, for: .border, edge: rectEdge)
            block.setBorderColor(borderColor, for: rectEdge)
        }

        // Breathing room: generous vertical padding. The left padding is kept
        // small so the callout's text lines up with a plain block quote's — the
        // shared hidden `> ` already provides the indent — rather than sitting
        // further right. (A block quote's left inset is its 2pt border; matching
        // that here keeps callouts and quotes aligned.)
        // Top padding lives in the header image (clickable text space); only the
        // bottom padding is block padding here.
        let leftPad: CGFloat = 2
        let rightPad: CGFloat = 10
        block.setWidth(calloutBottomPad, type: .absoluteValueType, for: .padding, edge: bottom)
        block.setWidth(leftPad, type: .absoluteValueType, for: .padding, edge: left)
        block.setWidth(rightPad, type: .absoluteValueType, for: .padding, edge: right)
        _ = top   // (top padding intentionally omitted — see header image)

        ps.textBlocks = [block]
        return ps
    }

    // MARK: Header image (icon + title)

    /// Draws "icon  Title" into one image, tinted to the callout color. Returns
    /// `nil` if the SF Symbol can't be resolved (the caller then leaves the raw
    /// marker text visible).
    private func calloutHeaderAttachment(symbolName: String, title: String, color: NSColor,
                                         iconNudge: CGFloat) -> NSTextAttachment? {
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
        // The image is taller than its content: the extra `calloutTopPad` sits on
        // top, so the callout's top breathing room is part of this (clickable)
        // header line rather than dead block padding above it.
        let topPad = ceil(calloutTopPad)
        let height = contentHeight + topPad

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            // Draw the content in the bottom `contentHeight` band; leave `topPad`
            // empty above it.
            let titleY = (contentHeight - titleSize.height) / 2
            titleStr.draw(at: NSPoint(x: symW + gap, y: titleY))
            // Center the icon on the title's cap height (its optical middle) rather
            // than the full line box, so tall-glyph symbols don't sit high.
            let baseline = titleY + abs(titleFont.descender)
            let capCenter = baseline + titleFont.capHeight / 2
            symbol.draw(in: NSRect(x: 0, y: capCenter - symH / 2 + iconNudge, width: symW, height: symH))
            return true
        }

        let attachment = NSTextAttachment()
        attachment.image = image
        // The content's bottom stays on the text baseline (as before); the extra
        // `topPad` extends the image (and the line fragment) upward.
        attachment.bounds = CGRect(x: 0, y: -pointSize * 0.15, width: width, height: height)
        return attachment
    }
}
