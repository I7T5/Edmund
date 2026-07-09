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
        /// `[ '[' … end-of-first-line )` — the marker plus any custom title.
        let headerRange: NSRange
        /// Capitalized type name, or the custom title if the header has one.
        let title: String
        /// When the header carries a custom title, the source range of that
        /// title text (leading whitespace trimmed). Rendered as real, wrapping
        /// text so a long title wraps inside the box instead of clipping. `nil`
        /// for a default callout, whose synthesized type name isn't in the
        /// source and stays a compact icon+name overlay.
        let customTitleRange: NSRange?
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

        // A custom title is the real source text after `]` (leading spaces
        // skipped). Rendered as live wrapping text; absent → default callout.
        var customTitleRange: NSRange?
        if !customRaw.trimmingCharacters(in: .whitespaces).isEmpty {
            var s = titleStart
            while s < lineEnd, ns.character(at: s) == 0x20 { s += 1 }
            customTitleRange = NSRange(location: s, length: lineEnd - s)
        }

        return CalloutInfo(marker: marker, style: style, headerRange: headerRange,
                           title: title, customTitleRange: customTitleRange)
    }

    /// Applies callout styling: the box, the icon + title header image, and the
    /// recursively-rendered body. Only called for an *inactive* callout — when
    /// the cursor is inside, the caller renders the raw `>` source instead so the
    /// markers stay editable.
    func styleCalloutContent(_ result: NSMutableAttributedString,
                             span: SyntaxHighlighter.Span,
                             info: CalloutInfo) {
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

        // End of the header (first) line, before any body lines.
        let headerNL = ns.range(of: "\n", options: [], range: span.fullRange)
        let headerLineEnd = headerNL.location == NSNotFound
            ? span.fullRange.upperBound : headerNL.location

        let header = info.headerRange
        let headerLine = NSRange(location: span.fullRange.location,
                                 length: headerLineEnd - span.fullRange.location)
        if header.length > 0, header.upperBound <= result.length {
            if let titleRange = info.customTitleRange, titleRange.upperBound <= result.length {
                // Custom title: hide the `[!type]` marker and render the title as
                // real bold + tinted text so a long title WRAPS inside the box.
                //
                // NOTE: the type icon here is a stroked vector *path* overlay,
                // never an image: drawing an image on this (potentially
                // multi-line, wrapping) header line wedges TextKit 2's layout to
                // a single line — clipping the title — by every image-drawing
                // mechanism tried, while shape drawing is unaffected. See
                // docs/investigations/archives/callout-title-wrap-investigation.md. Default callouts (the
                // `else` below) keep their icon+name image: their synthesized
                // type name is short and never wraps, so the single-line image
                // overlay never hits the wedge.
                let markerHide = NSRange(location: header.location,
                                         length: titleRange.location - header.location)
                if markerHide.length > 0 {
                    result.addAttribute(.font, value: hiddenFont, range: markerHide)
                    result.addAttribute(.foregroundColor, value: NSColor.clear, range: markerHide)
                }
                let titleFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
                result.addAttribute(.font, value: titleFont, range: titleRange)
                result.addAttribute(.foregroundColor, value: c.accent, range: titleRange)

                // Icon before the title: anchored on the hidden `[`, with the
                // kern reserving the icon's advance plus a gap so the title
                // starts clear of it (applyOverlay's own kern is only the icon
                // width — overwrite it).
                var iconAdvance: CGFloat = 0
                if let icon = calloutIconPathOverlay(iconName: info.style.iconName,
                                                     color: c.accent, titleFont: titleFont,
                                                     iconNudge: info.style.iconBaselineNudge) {
                    let anchor = NSRange(location: header.location, length: 1)
                    applyOverlay(icon, anchor: anchor, in: result)
                    iconAdvance = icon.bounds.width + bodyFont.pointSize * 0.3
                    result.addAttribute(.kern, value: iconAdvance, range: anchor)
                }

                // The title sits at the callout's left padding. The first line
                // carries the width-preserved `> ` marker before the (hidden)
                // `[!type]`, so its text starts `quoteMarkerWidth` past the
                // inset, plus the icon's kerned advance; headIndent adds both so
                // wrapped lines align under the title. Top breathing room is
                // above the first line only (the box covers it).
                let ps = NSMutableParagraphStyle()
                ps.lineSpacing = bodyParagraphStyle.lineSpacing
                ps.firstLineHeadIndent = 2
                ps.headIndent = 2 + quoteMarkerWidth + iconAdvance
                ps.tailIndent = -10
                ps.paragraphSpacingBefore = calloutTopPad
                result.addAttribute(.paragraphStyle, value: ps, range: headerLine)
            } else {
                // Default title (synthesized type name, not in the source, and
                // short enough never to wrap): hide the whole header and draw the
                // icon + name as one compact overlay image.
                result.addAttribute(.font, value: hiddenFont, range: header)
                result.addAttribute(.foregroundColor, value: NSColor.clear, range: header)
                if let overlay = calloutHeaderOverlay(iconName: info.style.iconName,
                                                      title: info.title, color: c.accent,
                                                      iconNudge: info.style.iconBaselineNudge) {
                    applyOverlay(overlay, anchor: NSRange(location: header.location, length: 1),
                                 in: result)
                    result.addAttribute(
                        .paragraphStyle,
                        value: calloutParagraphStyle(minimumLineHeight: overlay.bounds.height + calloutTopPad),
                        range: headerLine)
                }
            }
        }

        // Render the body (the lines after the header) recursively: strip one
        // `>` level, re-style the inner markdown, and splice it back so nested
        // code/quotes/callouts/lists/etc. render inside the box.
        renderCalloutBody(result, span: span, headerLineEnd: headerLineEnd)
    }

    /// Renders a callout's body — every line after the header — by stripping one
    /// level of `>` prefix, running the full `styleBlock` over the stripped
    /// inner markdown (which recurses into deeper callouts), and splicing the
    /// resulting attributes back onto the real characters with the prefixes
    /// hidden. Nested boxes/bars stack with the outer callout's box.
    private func renderCalloutBody(_ result: NSMutableAttributedString,
                                   span: SyntaxHighlighter.Span,
                                   headerLineEnd: Int) {
        let end = span.fullRange.upperBound
        // Body starts after the header line's trailing newline.
        guard headerLineEnd < end else { return }
        let bodyStart = headerLineEnd + 1   // skip the `\n`
        guard bodyStart < end else { return }

        let ns = result.string as NSString
        let space: unichar = 0x20, gt: unichar = 0x3E, newline: unichar = 0x0A

        // Build the stripped inner markdown (UTF-16 units) with a parallel map
        // back to real offsets, hide each line's `>` prefix, and remember each
        // line's real and stripped ranges so we can splice paragraph styles and
        // decorations per line.
        var units: [unichar] = []
        var realIndex: [Int] = []           // stripped UTF-16 offset → real offset
        var lineMap: [(real: NSRange, stripped: NSRange)] = []
        var cursor = bodyStart
        while cursor < end {
            let lineNL = ns.range(of: "\n", options: [],
                                  range: NSRange(location: cursor, length: end - cursor))
            let lineEnd = lineNL.location == NSNotFound ? end : lineNL.location

            // Leading `>` prefix: optional spaces, `>`, optional single space.
            var p = cursor
            while p < lineEnd, ns.character(at: p) == space { p += 1 }
            if p < lineEnd, ns.character(at: p) == gt {
                p += 1
                if p < lineEnd, ns.character(at: p) == space { p += 1 }
            }
            let prefixLen = p - cursor
            if prefixLen > 0 {
                let pr = NSRange(location: cursor, length: prefixLen)
                result.addAttribute(.font, value: hiddenFont, range: pr)
                result.addAttribute(.foregroundColor, value: NSColor.clear, range: pr)
            }

            let sStart = units.count
            for i in p..<lineEnd { units.append(ns.character(at: i)); realIndex.append(i) }
            lineMap.append((real: NSRange(location: cursor, length: lineEnd - cursor),
                            stripped: NSRange(location: sStart, length: units.count - sStart)))

            if lineEnd < end {
                units.append(newline); realIndex.append(lineEnd)   // keep the `\n`
                cursor = lineEnd + 1
            } else {
                cursor = end
            }
        }
        guard !units.isEmpty else { return }

        let stripped = String(utf16CodeUnits: units, count: units.count)

        // Segment the stripped body with BlockParser and style each block on
        // its own — mirroring the top-level pipeline. This enforces strict
        // `>`-prefix membership: a line without the deeper prefix is its own
        // block, so swift-markdown's lazy continuation can't pull a `> ` line
        // into an adjacent `> > ` callout/quote. The body is only rendered for an
        // inactive callout (the cursor is elsewhere), so inner blocks render
        // fully — no cursor reveal needed.
        let sub = NSMutableAttributedString(string: stripped, attributes: baseAttributes)
        for b in BlockParser.parse(stripped) {
            guard b.range.upperBound <= sub.length else { continue }
            let styled = styleBlock(b.content, cursorPosition: nil)
            styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length),
                                       options: []) { attrs, r, _ in
                sub.setAttributes(attrs,
                                  range: NSRange(location: r.location + b.range.location, length: r.length))
            }
        }

        spliceStyledBody(sub, realIndex: realIndex, lineMap: lineMap, into: result)
    }

    /// Splices an inner-rendered body (`sub`, in stripped space) back onto the
    /// real characters. Character attributes are mapped per run (skipping the
    /// hidden prefixes); paragraph styles and block decorations are applied per
    /// line, inset/stacked so inner content stays inside the outer box.
    private func spliceStyledBody(_ sub: NSAttributedString,
                                  realIndex: [Int],
                                  lineMap: [(real: NSRange, stripped: NSRange)],
                                  into result: NSMutableAttributedString) {
        let step = 2 + quoteMarkerWidth   // one nesting level of horizontal inset
        let subLen = sub.length

        // Character attributes (everything except paragraph style / decoration),
        // mapped from stripped offsets to real offsets in coalesced runs.
        sub.enumerateAttributes(in: NSRange(location: 0, length: subLen), options: []) { attrs, sr, _ in
            var ca = attrs
            ca[.paragraphStyle] = nil
            ca[.blockDecoration] = nil
            guard !ca.isEmpty else { return }
            var k = sr.location
            while k < sr.upperBound {
                let runStart = realIndex[k]
                var last = runStart
                var j = k + 1
                while j < sr.upperBound, realIndex[j] == last + 1 { last = realIndex[j]; j += 1 }
                result.addAttributes(ca, range: NSRange(location: runStart, length: last - runStart + 1))
                k = j
            }
        }

        // Paragraph styles and decorations, per body line.
        for lm in lineMap {
            let ss = lm.stripped.location
            guard ss < subLen else { continue }

            // Paragraph style: inset by one level so inner content stays inside
            // the box; preserve any inner style (list indent, centered math, …).
            let innerPS = (sub.attribute(.paragraphStyle, at: ss, effectiveRange: nil)
                as? NSParagraphStyle) ?? bodyParagraphStyle
            let ps = innerPS.mutableCopy() as! NSMutableParagraphStyle
            ps.firstLineHeadIndent += step
            ps.headIndent += step
            if ps.tailIndent == 0 { ps.tailIndent = -10 }
            result.addAttribute(.paragraphStyle, value: ps, range: lm.real)

            // Decoration: stack any inner box/bar (inset bumped) under the
            // outer callout box already present on this line.
            let innerDeco = sub.attribute(.blockDecoration, at: ss, effectiveRange: nil)
            let bumped = bumpedDecorations(innerDeco, by: step)
            if !bumped.isEmpty {
                var stack: [BlockDecoration] = []
                if let outer = result.attribute(.blockDecoration, at: lm.real.location,
                                                effectiveRange: nil) as? BlockDecoration {
                    stack.append(outer)
                }
                stack.append(contentsOf: bumped)
                result.addAttribute(.blockDecoration, value: BlockDecorationList(stack), range: lm.real)
            }
        }
    }

    /// Returns inner decorations with every `.box` inset increased by `step`
    /// (so a nested box sits within its parent); other kinds are unchanged.
    private func bumpedDecorations(_ value: Any?, by step: CGFloat) -> [BlockDecoration] {
        func bump(_ d: BlockDecoration) -> BlockDecoration {
            if case .box = d.kind { return BlockDecoration(d.kind, inset: d.inset + step) }
            return d
        }
        if let list = value as? BlockDecorationList { return list.decorations.map(bump) }
        if let single = value as? BlockDecoration { return [bump(single)] }
        return []
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

    /// Top breathing room — raised on the header line's minimum line height
    /// (clickable text space), not dead block padding.
    private var calloutTopPad: CGFloat { bodyFont.pointSize * 0.8 }
    /// Bottom breathing room. Delivered by growing the last line's layout
    /// fragment frame (a box `bottomPad`), so it is genuine clickable text
    /// space below the last line — not trailing paragraph spacing, which
    /// TextKit 2 leaves out of the fragment and which clicks would miss.
    /// Tuned so the *rendered* bottom gap matches the rendered top gap: the
    /// header overlay sits low in its line, so the top renders ~0.4·pointSize
    /// larger than `calloutTopPad`, and this makes the bottom match it.
    var calloutBottomPad: CGFloat { bodyFont.pointSize * 1.14 }

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

    // MARK: Header icon (custom title — stroked path, never an image)

    /// The type icon for a custom-title header, as a stroked-path overlay
    /// sized to a `pointSize` square and vertically centered on the bold
    /// title's optical middle (same optics as the header image below). A path
    /// — not an image — because the custom-title line wraps, and an image
    /// drawn on a multi-line fragment wedges its layout to one line (see
    /// docs/investigations/archives/callout-title-wrap-investigation.md). `nil` for an unknown icon.
    private func calloutIconPathOverlay(iconName: String, color: NSColor,
                                        titleFont: NSFont, iconNudge: CGFloat) -> FragmentOverlay? {
        let pointSize = bodyFont.pointSize
        guard let svgPath = LucideIcons.path(iconName) else { return nil }
        let scale = pointSize / 24   // Lucide viewBox → icon square
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        guard let scaled = svgPath.copy(using: &transform) else { return nil }
        // bounds.minY is the icon's *bottom* relative to the baseline: center
        // the square on the title's optical middle (midpoint of x-height and
        // cap-height centers — matches the header image's icon placement).
        let opticalCenter = (titleFont.xHeight + titleFont.capHeight) / 4
        return FragmentOverlay(path: scaled, color: color, lineWidth: 2 * scale,
                               bounds: CGRect(x: 0,
                                              y: opticalCenter - pointSize / 2 + iconNudge,
                                              width: pointSize, height: pointSize))
    }

    // MARK: Header image (icon + title)

    /// Draws "icon  Title" into one image, tinted to the callout color, and
    /// wraps it in a `FragmentOverlay`. Returns `nil` if the Lucide icon can't
    /// be resolved. The top breathing room is NOT in the image — the caller
    /// raises the header line's minimum line height instead.
    private func calloutHeaderOverlay(iconName: String, title: String, color: NSColor,
                                      iconNudge: CGFloat) -> FragmentOverlay? {
        let pointSize = bodyFont.pointSize
        guard let symbol = LucideIcons.image(iconName, color: color, pointSize: pointSize)
        else { return nil }

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
            // Center the icon on the visual middle of the bold title: the midpoint
            // between its x-height center (too low on its own) and cap-height center
            // (~1.5px too high on its own). This reads as centered for the
            // mostly-lowercase, capital-initial titles.
            let baseline = titleY + abs(titleFont.descender)
            let opticalCenter = baseline + (titleFont.xHeight + titleFont.capHeight) / 4
            symbol.draw(in: NSRect(x: 0, y: opticalCenter - symH / 2 + iconNudge, width: symW, height: symH))
            return true
        }
        // Re-rasterize at the screen's backing scale on every draw rather than
        // caching a 1× bitmap (which would render the composited title soft).
        image.cacheMode = .never

        return FragmentOverlay(image: image,
                               bounds: CGRect(x: 0, y: -pointSize * 0.15,
                                              width: width, height: contentHeight))
    }
}
