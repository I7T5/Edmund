import AppKit

// MARK: - Callout Rendering
//
// A callout is a block quote whose first line is `[!type]` (case-insensitive).
// swift-markdown gives us a plain `.blockquote` span; here we detect the marker
// on the first line and render it with a colored left bar + faint tint, an SF
// Symbol icon, and a colored type label — hiding the `[ ! ]` brackets when the
// item is rendered, and showing the raw marker (dimmed) when it's being edited.

extension EditorTextView {

    /// A detected callout on a block-quote span, with marker ranges already
    /// mapped to absolute offsets within the block string.
    struct CalloutInfo {
        let marker: Callout.Marker
        let style: CalloutStyle
    }

    /// Returns callout info if `span` (a `.blockquote`) begins with a known
    /// `[!type]` marker on its first line, else `nil` (a plain block quote).
    func calloutInfo(forBlockquote span: SyntaxHighlighter.Span, markdown: String) -> CalloutInfo? {
        // The first `> ` delimiter — the smallest-location one — opens line 1.
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
              let style = Callout.style(for: rel.type) else { return nil }

        func abs(_ r: NSRange) -> NSRange { NSRange(location: r.location + contentStart, length: r.length) }
        let marker = Callout.Marker(type: rel.type,
                                    openBracket: abs(rel.openBracket),
                                    typeRange: abs(rel.typeRange),
                                    closeBracket: abs(rel.closeBracket))
        return CalloutInfo(marker: marker, style: style)
    }

    /// Applies callout styling to a block-quote span detected as a callout.
    /// `active` shows the raw marker (dimmed, editable); otherwise the marker is
    /// rendered as an icon + colored type label with the brackets hidden.
    func styleCalloutContent(_ result: NSMutableAttributedString,
                             span: SyntaxHighlighter.Span,
                             info: CalloutInfo,
                             active: Bool) {
        guard span.fullRange.upperBound <= result.length else { return }
        let color = NSColor(hex: info.style.colorHex) ?? accentColor

        // Colored left bar + faint tint behind the whole callout.
        result.addAttribute(.paragraphStyle, value: calloutParagraphStyle(color: color),
                            range: span.fullRange)

        let m = info.marker
        if active {
            // Editing: keep the raw "[!type]" visible but dimmed.
            let full = NSRange(location: m.openBracket.location,
                               length: m.closeBracket.upperBound - m.openBracket.location)
            if full.upperBound <= result.length {
                result.addAttribute(.foregroundColor, value: syntaxDimColor, range: full)
            }
            return
        }

        // Rendered: icon replaces "[", hide "!" and "]", color the type label.
        if let icon = calloutIconAttachment(symbolName: info.style.symbolName, color: color),
           m.openBracket.location < result.length {
            result.addAttribute(.attachment, value: icon,
                                range: NSRange(location: m.openBracket.location, length: 1))
        }
        hideCalloutRange(result, NSRange(location: m.openBracket.location + 1, length: 1)) // "!"
        if m.typeRange.upperBound <= result.length {
            let bold = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
            result.addAttribute(.foregroundColor, value: color, range: m.typeRange)
            result.addAttribute(.font, value: bold, range: m.typeRange)
        }
        hideCalloutRange(result, m.closeBracket) // "]"
    }

    private func hideCalloutRange(_ result: NSMutableAttributedString, _ r: NSRange) {
        guard r.upperBound <= result.length else { return }
        result.addAttribute(.font, value: hiddenFont, range: r)
        result.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
    }

    /// Paragraph style for a callout: a thick colored left bar and a faint tint
    /// of the same color behind the block.
    private func calloutParagraphStyle(color: NSColor) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = bodyParagraphStyle.lineSpacing
        ps.paragraphSpacing = bodyParagraphStyle.paragraphSpacing

        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)
        let leftEdge = NSRectEdge(rawValue: 0)!
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: leftEdge)
        block.setBorderColor(color, for: leftEdge)
        block.setWidth(8, type: .absoluteValueType, for: .padding, edge: leftEdge)
        block.backgroundColor = color.withAlphaComponent(0.08)
        ps.textBlocks = [block]
        return ps
    }

    /// An SF Symbol icon attachment tinted to the callout color, sized to the
    /// body font with a small trailing gap before the label. `nil` if the symbol
    /// can't be resolved.
    private func calloutIconAttachment(symbolName: String, color: NSColor) -> NSTextAttachment? {
        let pointSize = bodyFont.pointSize
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }

        let attachment = NSTextAttachment()
        attachment.image = image
        let gap = pointSize * 0.35
        attachment.bounds = CGRect(x: 0, y: -pointSize * 0.12,
                                   width: image.size.width + gap, height: image.size.height)
        return attachment
    }
}
