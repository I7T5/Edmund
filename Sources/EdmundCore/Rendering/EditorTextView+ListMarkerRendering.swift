import AppKit

/// List-item marker styling: maps a list item's leading whitespace to a nesting
/// depth, indents the content by one marker "slot" per level (Apple Notes
/// style), and positions the raw/rendered marker so the text column stays put
/// whether or not the caret is inside the item. Extracted from the `styleBlock`
/// switch in EditorTextView+Rendering.
extension EditorTextView {

    /// Styles the `.listItem` content for one span. The caller has already
    /// bounds-checked `span.fullRange` against `result`.
    func styleListItemSpan(_ result: NSMutableAttributedString,
                           span: SyntaxHighlighter.Span,
                           markdown: String,
                           ordered: Bool,
                           checkbox: SyntaxHighlighter.Span.Kind.CheckboxState?,
                           cursorInToken: Bool) {
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
        let depth = listDepth(leadingWhitespace: String(leadingWS))
        let markerStart = listPadding + CGFloat(depth) * slotWidth
        let contentIndent = markerStart + slotWidth
        // The visible marker text ("- ", "1. ", "- [ ] "), without the
        // leading whitespace (which we hide below).
        let markerText = String(markerStr.dropFirst(leadingWS.count))
        let markerWidth = (markerText as NSString).size(withAttributes: [.font: bodyFont]).width
        let firstLineIndent: CGFloat
        // For an active bullet we left-shift the raw "-" onto the dot's
        // column; this kern widens its trailing space so the content
        // still begins at contentIndent (set after the paragraph style).
        var activeBulletSpaceKern: CGFloat = 0
        if ordered || (cursorInToken && checkbox != nil) {
            // Ordered marker, or an active checkbox: right-align the marker
            // into its slot so the content begins at `contentIndent` — the
            // same place as the rendered (inactive) form. This keeps the
            // item aligned at every depth (and clicking in doesn't shift
            // the text), while leaving the raw "1." / "- [ ]" editable.
            // Wrapped lines hang at contentIndent via headIndent.
            firstLineIndent = max(2, contentIndent - markerWidth)
        } else if cursorInToken {
            // Active bullet: sit the raw "-" on the dot's column instead of
            // right-aligning it into the slot, so the marker doesn't jump
            // sideways when you click into the item. The inactive dot is
            // centered in a pointSize-wide box at markerStart, so center the
            // dash there too; the kern below keeps the content at
            // contentIndent.
            let dashWidth = ("-" as NSString).size(withAttributes: [.font: bodyFont]).width
            firstLineIndent = max(2, markerStart + (bodyFont.pointSize - dashWidth) / 2)
            activeBulletSpaceKern = max(0, contentIndent - (firstLineIndent + markerWidth))
        } else {
            // Inactive bullet/checkbox: the marker icon sits at markerStart.
            firstLineIndent = markerStart
        }
        // Hide the leading indentation — the indent is provided entirely by
        // the paragraph style. swift-markdown's list-item delimiter range
        // starts at the marker and excludes this whitespace, so without
        // hiding it here those spaces render visibly and push the first line
        // right, breaking alignment with the hanging (wrapped-line) indent.
        // (The deep-indent rescue parser already includes the whitespace in
        // its delimiter; the delimiter styling below avoids re-showing it.)
        let wsLen = leadingWS.count
        if wsLen > 0 {
            let lead = NSRange(location: 0, length: wsLen)
            result.addAttribute(.font, value: hiddenFont, range: lead)
            result.addAttribute(.foregroundColor, value: NSColor.clear, range: lead)
        }
        // Apply paragraph style from position 0 — NSTextView uses the paragraph
        // style from the first character of a paragraph.
        result.addAttribute(.paragraphStyle,
                            value: listParagraphStyle(firstLineIndent: firstLineIndent, contentIndent: contentIndent),
                            range: NSRange(location: 0, length: result.length))
        // Active bullet: widen the marker's trailing space so the content
        // lands at contentIndent even though the "-" sits on the dot column.
        if activeBulletSpaceKern > 0, span.contentRange.location > 0,
           span.contentRange.location <= result.length {
            result.addAttribute(.kern, value: activeBulletSpaceKern,
                                range: NSRange(location: span.contentRange.location - 1, length: 1))
        }
        // Strikethrough checked items
        if !ordered, checkbox == .checked {
            result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.contentRange)
            result.addAttribute(.foregroundColor, value: syntaxDimColor, range: span.contentRange)
        }
    }
}
