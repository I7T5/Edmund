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
                                             title: info.title, color: c.accent) {
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

        // Breathing room: vertical (item) + horizontal padding.
        let vPad = bodyFont.pointSize * 0.45
        let hPad: CGFloat = 10
        block.setWidth(vPad, type: .absoluteValueType, for: .padding, edge: top)
        block.setWidth(vPad, type: .absoluteValueType, for: .padding, edge: bottom)
        block.setWidth(hPad, type: .absoluteValueType, for: .padding, edge: left)
        block.setWidth(hPad, type: .absoluteValueType, for: .padding, edge: right)

        ps.textBlocks = [block]
        return ps
    }

    // MARK: Header image (icon + title)

    /// Draws "icon  Title" into one image, tinted to the callout color. Returns
    /// `nil` if the SF Symbol can't be resolved (the caller then leaves the raw
    /// marker text visible).
    private func calloutHeaderAttachment(symbolName: String, title: String, color: NSColor) -> NSTextAttachment? {
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
        let height = ceil(max(symH, titleSize.height))
        let width = ceil(symW + gap + titleSize.width)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            symbol.draw(in: NSRect(x: 0, y: (height - symH) / 2, width: symW, height: symH))
            titleStr.draw(at: NSPoint(x: symW + gap, y: (height - titleSize.height) / 2))
            return true
        }

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -pointSize * 0.15, width: width, height: height)
        return attachment
    }
}
